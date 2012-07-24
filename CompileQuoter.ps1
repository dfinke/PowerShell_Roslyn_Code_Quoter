$referencedAssemblies = .\ReferencedAssemblies.ps1

Add-Type -ReferencedAssemblies $referencedAssemblies @"
using System;
using System.Collections;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;
using System.Text;
using Roslyn.Compilers.CSharp;

public class Quoter
{
    public bool OpenParenthesisOnNewLine { get; set; }
    public bool ClosingParenthesisOnNewLine { get; set; }

    /// <summary>
    /// Given the input C# program <paramref name="sourceText"/> returns the C# source code of
    /// Roslyn API calls that recreate the syntax tree for the input program.
    /// </summary>
    /// <param name="sourceText">A C# program (one compilation unit)</param>
    /// <returns>A C# expression that describes calls to the Roslyn syntax API necessary to recreate
    /// the syntax tree for the source program.</returns>
    public string Quote(string sourceText)
    {
        SyntaxTree sourceTree = SyntaxTree.ParseCompilationUnit(sourceText);
        ApiCall rootApiCall = Quote(sourceTree.GetRoot());
        string generatedCode = Print(rootApiCall);
        return generatedCode;
    }

    /// <summary>
    /// Recursive method that "quotes" a SyntaxNode, SyntaxToken, SyntaxTrivia or other objects.
    /// </summary>
    /// <returns>A description of Roslyn API calls necessary to recreate the input object.</returns>
    private ApiCall Quote(object treeElement, string name = null)
    {
        if (treeElement is SyntaxTrivia)
        {
            return QuoteTrivia((SyntaxTrivia)treeElement);
        }

        if (treeElement is SyntaxToken)
        {
            return QuoteToken((SyntaxToken)treeElement, name);
        }

        if (treeElement is SyntaxNodeOrToken)
        {
            SyntaxNodeOrToken syntaxNodeOrToken = (SyntaxNodeOrToken)treeElement;
            if (syntaxNodeOrToken.IsNode)
            {
                return QuoteNode(syntaxNodeOrToken.AsNode(), name);
            }
            else
            {
                return QuoteToken(syntaxNodeOrToken.AsToken(), name);
            }
        }

        return QuoteNode((SyntaxNode)treeElement, name);
    }

    /// <summary>
    /// The main recursive method that given a SyntaxNode recursively quotes the entire subtree.
    /// </summary>
    private ApiCall QuoteNode(SyntaxNode node, string name)
    {
        List<ApiCall> quotedPropertyValues = QuotePropertyValues(node);
        MethodInfo factoryMethod = PickFactoryMethodToCreateNode(node);

        var factoryMethodCall = new MethodCall()
        {
            Name = factoryMethod.DeclaringType.Name + "." + factoryMethod.Name
        };

        var codeBlock = new ApiCall(name, factoryMethodCall);

        AddFactoryMethodArguments(factoryMethod, factoryMethodCall, quotedPropertyValues);
        AddModifyingCalls(node, codeBlock, quotedPropertyValues);

        return codeBlock;
    }

    /// <summary>
    /// Inspects the property values of the <paramref name="node"/> object using Reflection and
    /// creates API call descriptions for the property values recursively. Properties that are not
    /// essential to the shape of the syntax tree (such as Span) are ignored.
    /// </summary>
    private List<ApiCall> QuotePropertyValues(SyntaxNode node)
    {
        var result = new List<ApiCall>();

        var properties = node.GetType().GetProperties(BindingFlags.Public | BindingFlags.Instance);

        // Filter out non-essential properties listed in nonStructuralProperties
        result.AddRange(properties
            .Where(propertyInfo => !nonStructuralProperties.Contains(propertyInfo.Name))
            .Select(propertyInfo => QuotePropertyValue(node, propertyInfo))
            .Where(apiCall => apiCall != null));

        // HACK: factory methods for the following node types accept back the first "kind" parameter
        // that we filter out above. Add an artificial "property value" that can be later used to
        // satisfy the first parameter of type SyntaxKind.
        if (node is AccessorDeclarationSyntax ||
            node is BinaryExpressionSyntax ||
            node is ClassOrStructConstraintSyntax ||
            node is CheckedExpressionSyntax ||
            node is CheckedStatementSyntax ||
            node is ConstructorInitializerSyntax ||
            node is GotoStatementSyntax ||
            node is InitializerExpressionSyntax ||
            node is LiteralExpressionSyntax ||
            node is MemberAccessExpressionSyntax ||
            node is OrderingSyntax ||
            node is PostfixUnaryExpressionSyntax ||
            node is PrefixUnaryExpressionSyntax ||
            node is SwitchLabelSyntax ||
            node is YieldStatementSyntax)
        {
            result.Add(new ApiCall("Kind", "SyntaxKind." + node.Kind.ToString()));
        }

        return result;
    }

    /// <summary>
    /// Quote the value of the property <paramref name="property"/> of object <paramref
    /// name="node"/>
    /// </summary>
    private ApiCall QuotePropertyValue(SyntaxNode node, PropertyInfo property)
    {
        var value = property.GetValue(node, null);
        var propertyType = property.PropertyType;

        if (propertyType == typeof(SyntaxToken))
        {
            return QuoteToken((SyntaxToken)value, property.Name);
        }

        if (propertyType == typeof(SyntaxTokenList))
        {
            return QuoteList((IEnumerable)value, property.Name);
        }

        if (propertyType.IsGenericType &&
            (propertyType.GetGenericTypeDefinition() == typeof(SyntaxList<>) ||
             propertyType.GetGenericTypeDefinition() == typeof(SeparatedSyntaxList<>)))
        {
            return QuoteList((IEnumerable)value, property.Name);
        }

        if (value is SyntaxNode)
        {
            return QuoteNode((SyntaxNode)value, property.Name);
        }

        if (value is string)
        {
            return new ApiCall(property.Name, "\"" + Escape(value.ToString()) + "\"");
        }

        if (value is bool)
        {
            return new ApiCall(property.Name, value.ToString().ToLowerInvariant());
        }

        return null;
    }

    private ApiCall QuoteList(IEnumerable syntaxList, string name)
    {
        IEnumerable<object> sourceList = syntaxList.Cast<object>();

        string methodName = "Syntax.List";
        var propertyType = syntaxList.GetType();
        if (propertyType.IsGenericType)
        {
            if (propertyType.GetGenericTypeDefinition() == typeof(SeparatedSyntaxList<>))
            {
                methodName = "Syntax.SeparatedList";
                sourceList = ((SyntaxNodeOrTokenList)
                    syntaxList.GetType().GetMethod("GetWithSeparators").Invoke(syntaxList, null))
                    .Cast<object>()
                    .ToArray();
            }

            methodName += "<" + propertyType.GetGenericArguments()[0].Name + ">";
        }

        if (propertyType.Name == "SyntaxTokenList")
        {
            methodName = "Syntax.TokenList";
        }

        if (propertyType.Name == "SyntaxTriviaList")
        {
            methodName = "Syntax.TriviaList";
        }

        var elements = new List<object>(sourceList
            .Select(o => Quote(o))
            .Where(cb => cb != null));
        if (elements.Count == 0)
        {
            return null;
        }

        var codeBlock = new ApiCall(name, methodName, elements);

        return codeBlock;
    }

    private ApiCall QuoteToken(SyntaxToken value, string name)
    {
        if (value == default(SyntaxToken) || value.Kind == SyntaxKind.None)
        {
            return null;
        }

        var arguments = new List<object>();
        string methodName = "Syntax.Token";
        string escapedTokenValueText = "@\"" + Escape(value.GetText()) + "\"";

        if (value.Kind == SyntaxKind.IdentifierToken)
        {
            methodName = "Syntax.Identifier";

            AddLeadingTrivia(value, arguments);
            arguments.Add(escapedTokenValueText);
            AddTrailingTrivia(value, arguments, addEvenEmptyTrivia: value.HasLeadingTrivia);
        }
        else if (value.Kind == SyntaxKind.XmlTextLiteralToken ||
            value.Kind == SyntaxKind.XmlTextLiteralNewLineToken ||
            value.Kind == SyntaxKind.XmlEntityLiteralToken)
        {
            methodName = "Syntax.XmlText";
            if (value.Kind == SyntaxKind.XmlTextLiteralNewLineToken)
            {
                methodName = "Syntax.XmlTextNewLine";
            }
            else if (value.Kind == SyntaxKind.XmlEntityLiteralToken)
            {
                methodName = "Syntax.XmlEntity";
            }

            AddLeadingTrivia(value, arguments, addEvenEmptyTrivia: true);
            arguments.Add(escapedTokenValueText);
            arguments.Add(escapedTokenValueText);
            AddTrailingTrivia(value, arguments, addEvenEmptyTrivia: true);
        }
        else if ((value.Parent is LiteralExpressionSyntax ||
            value.Kind == SyntaxKind.StringLiteralToken ||
            value.Kind == SyntaxKind.NumericLiteralToken) &&
            value.Kind != SyntaxKind.TrueKeyword &&
            value.Kind != SyntaxKind.FalseKeyword &&
            value.Kind != SyntaxKind.NullKeyword)
        {
            methodName = "Syntax.Literal";

            AddLeadingTrivia(value, arguments, addEvenEmptyTrivia: true);
            arguments.Add(escapedTokenValueText);
            arguments.Add(value.GetText());
            AddTrailingTrivia(value, arguments, addEvenEmptyTrivia: true);
        }
        else
        {
            if (value.IsMissing)
            {
                methodName = "Syntax.MissingToken";
            }

            if (value.Kind == SyntaxKind.BadToken)
            {
                methodName = "Syntax.BadToken";
            }

            bool addEvenEmptyTrivia = value.Kind == SyntaxKind.BadToken;
            object tokenValue = value.Kind;

            if (value.Kind == SyntaxKind.BadToken)
            {
                tokenValue = escapedTokenValueText;
            }

            AddLeadingTrivia(value, arguments, addEvenEmptyTrivia: addEvenEmptyTrivia);
            arguments.Add(tokenValue);
            AddTrailingTrivia(value, arguments, addEvenEmptyTrivia: addEvenEmptyTrivia);
        }

        return new ApiCall(name, methodName, arguments);
    }

    private void AddLeadingTrivia(SyntaxToken value, List<Object> arguments, bool addEvenEmptyTrivia = false)
    {
        if (value.HasLeadingTrivia || value.HasTrailingTrivia)
        {
            if (value.IsMissing)
            {
                addEvenEmptyTrivia = true;
            }

            var quotedLeadingTrivia = QuoteList(value.LeadingTrivia, "LeadingTrivia");
            if (quotedLeadingTrivia != null)
            {
                arguments.Add(quotedLeadingTrivia);
                return;
            }
        }

        AddEmptyTrivia(arguments, addEvenEmptyTrivia, "LeadingTrivia");
    }

    private void AddTrailingTrivia(SyntaxToken value, List<Object> arguments, bool addEvenEmptyTrivia = false)
    {
        if (value.IsMissing && (value.HasLeadingTrivia || value.HasTrailingTrivia))
        {
            addEvenEmptyTrivia = true;
        }

        if (value.HasTrailingTrivia)
        {
            var quotedTrailingTrivia = QuoteList(value.TrailingTrivia, "TrailingTrivia");
            if (quotedTrailingTrivia != null)
            {
                arguments.Add(quotedTrailingTrivia);
                return;
            }
        }

        AddEmptyTrivia(arguments, addEvenEmptyTrivia, "TrailingTrivia");
    }

    private void AddEmptyTrivia(List<object> arguments, bool addEvenEmptyTrivia, string name)
    {
        if (addEvenEmptyTrivia)
        {
            arguments.Add(new ApiCall(name, "Syntax.TriviaList", arguments: null));
        }
    }

    private ApiCall QuoteTrivia(SyntaxTrivia syntaxTrivia)
    {
        FieldInfo field = null;
        if (triviaFactoryFields.TryGetValue(syntaxTrivia.GetText(), out field))
        {
            return new ApiCall(null, "Syntax." + field.Name);
        }

        string factoryMethodName = "Syntax.Trivia";
        string text = syntaxTrivia.GetText();
        if (text != null && text.Length > 0 && string.IsNullOrWhiteSpace(text))
        {
            factoryMethodName = "Syntax.Whitespace";
        }

        if (syntaxTrivia.Kind == SyntaxKind.SingleLineCommentTrivia ||
            syntaxTrivia.Kind == SyntaxKind.MultiLineCommentTrivia)
        {
            factoryMethodName = "Syntax.Comment";
        }

        if (syntaxTrivia.Kind == SyntaxKind.PreprocessingMessageTrivia)
        {
            factoryMethodName = "Syntax.PreprocessingMessage";
        }

        if (syntaxTrivia.Kind == SyntaxKind.DisabledTextTrivia)
        {
            factoryMethodName = "Syntax.DisabledText";
        }

        if (syntaxTrivia.Kind == SyntaxKind.DocumentationCommentExteriorTrivia)
        {
            factoryMethodName = "Syntax.DocumentationCommentExteriorTrivia";
        }

        object argument = "@\"" + Escape(syntaxTrivia.GetText()) + "\"";

        if (syntaxTrivia.HasStructure)
        {
            argument = QuoteNode(syntaxTrivia.GetStructure(), "Structure");
        }

        return new ApiCall(null, factoryMethodName, CreateArgumentList(argument));
    }

    private void AddFactoryMethodArguments(
        MethodInfo factory,
        MethodCall factoryMethodCall,
        List<ApiCall> quotedValues)
    {
        foreach (var factoryMethodParameter in factory.GetParameters())
        {
            var parameterName = factoryMethodParameter.Name;
            var parameterType = factoryMethodParameter.ParameterType;

            ApiCall quotedCodeBlock = FindValue(parameterName, quotedValues);

            if (parameterName == "name" && quotedCodeBlock == null)
            {
                quotedCodeBlock = FindValue("Identifier", quotedValues);
            }

            if (parameterName == "identifier" && quotedCodeBlock == null)
            {
                quotedCodeBlock = new ApiCall(
                    null,
                    "Syntax.MissingToken",
                    CreateArgumentList(SyntaxKind.IdentifierToken));
            }

            if (quotedCodeBlock != null)
            {
                factoryMethodCall.AddArgument(quotedCodeBlock);
                quotedValues.Remove(quotedCodeBlock);
            }
        }
    }

    /// <summary>
    /// Helper to quickly create a list from one or several items
    /// </summary>
    private static List<object> CreateArgumentList(params object[] args)
    {
        return new List<object>(args);
    }

    /// <summary>
    /// Escapes strings to be included within "" using C# escaping rules
    /// </summary>
    private string Escape(string text)
    {
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < text.Length; i++)
        {
            if (text[i] == '"')
            {
                sb.Append("\"\"");
            }
            else
            {
                sb.Append(text[i]);
            }
        }

        return sb.ToString();
    }

    /// <summary>
    /// Finds a value in a list using case-insensitive search
    /// </summary>
    private ApiCall FindValue(string parameterName, IEnumerable<ApiCall> values)
    {
        return values.FirstOrDefault(
            v => parameterName.Equals(v.Name, StringComparison.OrdinalIgnoreCase));
    }

    /// <summary>
    /// Static methods on Roslyn.Compilers.CSharp.Syntax class that construct SyntaxNodes
    /// </summary>
    /// <example>Syntax.ClassDeclaration()</example>
    private static readonly Dictionary<string, List<MethodInfo>> factoryMethods = GetFactoryMethods();

    /// <summary>
    /// Five public fields on Roslyn.Compilers.CSharp.Syntax that return trivia: CarriageReturn,
    /// LineFeed, CarriageReturnLineFeed, Space and Tab.
    /// </summary>
    private static readonly Dictionary<string, FieldInfo> triviaFactoryFields = GetTriviaFactoryFields();

    /// <summary>
    /// Gets the five fields on Syntax that return ready-made trivia: CarriageReturn,
    /// CarriageReturnLineFeed, LineFeed, Space and Tab.
    /// </summary>
    private static Dictionary<string, FieldInfo> GetTriviaFactoryFields()
    {
        var result = typeof(Syntax)
            .GetFields(BindingFlags.Public | BindingFlags.Static)
            .Where(fieldInfo => fieldInfo.FieldType == typeof(SyntaxTrivia))
            .Where(fieldInfo => !fieldInfo.Name.Contains("Elastic"))
            .ToDictionary(fieldInfo => ((SyntaxTrivia)fieldInfo.GetValue(null)).GetText());

        return result;
    }

    /// <summary>
    /// Returns static methods on Roslyn.Compilers.CSharp.Syntax that return types derived from
    /// SyntaxNode and bucketizes them by overloads.
    /// </summary>
    private static Dictionary<string, List<MethodInfo>> GetFactoryMethods()
    {
        var result = new Dictionary<string, List<MethodInfo>>();

        var staticMethods = typeof(Syntax).GetMethods(
            BindingFlags.Public | BindingFlags.Static);

        foreach (var method in staticMethods)
        {
            var returnTypeName = method.ReturnType.Name;

            List<MethodInfo> bucket = null;
            if (!result.TryGetValue(returnTypeName, out bucket))
            {
                bucket = new List<MethodInfo>();
                result.Add(returnTypeName, bucket);
            }

            bucket.Add(method);
        }

        return result;
    }

    /// <summary>
    /// Uses Reflection to inspect static factory methods on the Roslyn.Compilers.CSharp.Syntax
    /// class and pick an overload that creates a node of the same type as the input <paramref
    /// name="node"/>
    /// </summary>
    private MethodInfo PickFactoryMethodToCreateNode(SyntaxNode node)
    {
        string name = node.GetType().Name;

        List<MethodInfo> candidates = null;
        if (!factoryMethods.TryGetValue(name, out candidates))
        {
            throw new NotSupportedException(name + " is not supported");
        }

        int minParameterCount = candidates.Min(m => m.GetParameters().Length);

        // HACK: for LiteralExpression pick the overload with two parameters - the overload with one
        // parameter only allows true/false/null literals
        if (node is LiteralExpressionSyntax)
        {
            SyntaxKind kind = ((LiteralExpressionSyntax)node).Kind;
            if (kind != SyntaxKind.TrueLiteralExpression &&
                kind != SyntaxKind.FalseLiteralExpression &&
                kind != SyntaxKind.NullLiteralExpression)
            {
                minParameterCount = 2;
            }
        }

        if (node is PragmaChecksumDirectiveSyntax)
        {
            // TODO: apparently calling the overload Syntax.PragmaChecksumDirectiveTrivia(bool)
            // fails (bug 15121)
            minParameterCount = 8;
        }

        MethodInfo factory = candidates.First(m => m.GetParameters().Length == minParameterCount);
        return factory;
    }

    /// <summary>
    /// Adds information about subsequent modifying fluent interface style calls on an object (like
    /// foo.With(...).With(...))
    /// </summary>
    private void AddModifyingCalls(object treeElement, ApiCall apiCall, List<ApiCall> values)
    {
        var methods = treeElement.GetType().GetMethods(BindingFlags.Public | BindingFlags.Instance);

        foreach (var value in values)
        {
            var properCase = ProperCase(value.Name);
            var methodName = "With" + properCase;
            if (methods.Any(m => m.Name == methodName))
            {
                methodName = "." + methodName;
            }
            else
            {
                throw new NotSupportedException();
            }

            var methodCall = new MethodCall
            {
                Name = methodName,
                Arguments = CreateArgumentList(value)
            };

            apiCall.Add(methodCall);
        }
    }

    /// <summary>
    /// Flattens a tree of ApiCalls into a single string.
    /// </summary>
    private string Print(ApiCall root)
    {
        var sb = new StringBuilder();
        Print(root, sb);
        var generatedCode = sb.ToString();
        return generatedCode;
    }

    private void Print(ApiCall codeBlock, StringBuilder sb, int depth = 0)
    {
        Print(codeBlock.FactoryMethodCall, sb, depth);
        if (codeBlock.InstanceMethodCalls != null)
        {
            foreach (var call in codeBlock.InstanceMethodCalls)
            {
                PrintNewLine(sb);
                Print(call, sb, depth);
            }
        }
    }

    private void Print(MemberCall call, StringBuilder sb, int depth)
    {
        Print(call.Name, sb, depth);

        MethodCall methodCall = call as MethodCall;
        if (methodCall != null)
        {
            if (methodCall.Arguments == null || !methodCall.Arguments.Any())
            {
                Print("()", sb, 0);
                return;
            }

            if (OpenParenthesisOnNewLine)
            {
                PrintNewLine(sb);
                Print("(", sb, depth);
            }
            else
            {
                Print("(", sb, 0);
            }

            PrintNewLine(sb);

            bool needComma = false;
            foreach (var block in methodCall.Arguments)
            {
                if (needComma)
                {
                    Print(",", sb, 0);
                    PrintNewLine(sb);
                }

                if (block is string)
                {
                    Print((string)block, sb, depth + 1);
                }
                else if (block is SyntaxKind)
                {
                    Print("SyntaxKind." + ((SyntaxKind)block).ToString(), sb, depth + 1);
                }
                else if (block is ApiCall)
                {
                    Print(block as ApiCall, sb, depth + 1);
                }

                needComma = true;
            }

            if (ClosingParenthesisOnNewLine)
            {
                PrintNewLine(sb);
                Print(")", sb, depth);
            }
            else
            {
                Print(")", sb, 0);
            }
        }
    }

    private void PrintNewLine(StringBuilder sb)
    {
        sb.AppendLine();
    }

    private void Print(string line, StringBuilder sb, int indent)
    {
        PrintIndent(sb, indent);
        sb.Append(line);
    }

    private void PrintIndent(StringBuilder sb, int indent)
    {
        sb.Append(new string(' ', indent * 4));
    }

    private string ProperCase(string str)
    {
        return char.ToUpperInvariant(str[0]) + str.Substring(1);
    }

    /// <summary>
    /// Enumerates names of properties on SyntaxNode, SyntaxToken and SyntaxTrivia classes that do
    /// not impact the shape of the syntax tree and are not essential to reconstructing the tree.
    /// </summary>
    private static readonly string[] nonStructuralProperties =
    {
        "AllowsAnyExpression",
        "Arity",
        "HasAnyAnnotations",
        "HasDiagnostics",
        "HasDirectives",
        "DirectiveNameToken",
        "FullSpan",
        "HasLeadingTrivia",
        "HasTrailingTrivia",
        "HasStructure",
        "IsConst",
        "IsDirective",
        "IsElastic",
        "IsFixed",
        "IsMissing",
        "IsStructuredTrivia",
        "IsUnboundGenericName",
        "IsVar",
        "Kind",
        "Language",
        "Parent",
        "ParentTrivia",
        "PlainName",
        "Span",
        "SyntaxTree",
    };

    /// <summary>
    /// "Stringly typed" representation of a C# property or method invocation expression, with a
    /// string for the property or method name and a list of similarly loosely typed argument
    /// expressions. Simply speaking, this is a tree of strings.
    /// </summary>
    /// <example>
    /// Data structure to represent code (API calls) of simple hierarchical shape such as:
    /// A.B(C, D.E(F(G, H), I))
    /// </example>
    private class ApiCall
    {
        public string Name { get; private set; }
        public MemberCall FactoryMethodCall { get; private set; }
        public List<MethodCall> InstanceMethodCalls { get; private set; }

        public ApiCall()
        {
        }

        public ApiCall(string parentPropertyName, string factoryMethodName)
        {
            Name = parentPropertyName;
            FactoryMethodCall = new MemberCall
            {
                Name = factoryMethodName
            };
        }

        public ApiCall(string parentPropertyName, string factoryMethodName, List<object> arguments)
        {
            Name = parentPropertyName;
            FactoryMethodCall = new MethodCall
            {
                Name = factoryMethodName,
                Arguments = arguments
            };
        }

        public ApiCall(string name, MethodCall factoryMethodCall)
        {
            Name = name;
            FactoryMethodCall = factoryMethodCall;
        }

        public void Add(MethodCall methodCall)
        {
            if (InstanceMethodCalls == null)
            {
                InstanceMethodCalls = new List<MethodCall>();
            }

            InstanceMethodCalls.Add(methodCall);
        }
    }

    /// <summary>
    /// Simple data structure to represent a member call, primarily just the string Name.
    /// </summary>
    private class MemberCall
    {
        public string Name { get; set; }
    }

    /// <summary>
    /// Represents a method call that has a Name and an arbitrary list of Arguments.
    /// </summary>
    private class MethodCall : MemberCall
    {
        public List<object> Arguments { get; set; }

        public void AddArgument(object value)
        {
            if (Arguments == null)
            {
                Arguments = new List<object>();
            }

            Arguments.Add(value);
        }
    }
}
"@