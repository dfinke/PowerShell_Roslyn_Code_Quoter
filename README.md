PowerShell Roslyn Code Quoter
=============================
Transcoded from Kirill Osenkov http://code.msdn.microsoft.com/Roslyn-Code-Quoter-f724259e
Blog post http://blogs.msdn.com/b/kirillosenkov/archive/2012/07/22/roslyn-code-quoter-tool-generating-syntax-tree-api-calls-for-any-c-program.aspx

Run It
======
```PowerShell
    .\quoting.ps1 "var x = 1;"
```
Result
======
    Source        : var x = 1;
    Evaluated     : var x = 1;
    GeneratedCode : Syntax.CompilationUnit()
                    .WithMembers(
                        Syntax.List<MemberDeclarationSyntax>(
                            Syntax.FieldDeclaration(
                                Syntax.VariableDeclaration(
                                    Syntax.IdentifierName(
                                        Syntax.Identifier(
                                            @"var",
                                            Syntax.TriviaList(
                                                Syntax.Space))))
                                .WithVariables(
                                    Syntax.SeparatedList<VariableDeclaratorSyntax>(
                                        Syntax.VariableDeclarator(
                                            Syntax.Identifier(
                                                @"x",
                                                Syntax.TriviaList(
                                                    Syntax.Space)))
                                        .WithInitializer(
                                            Syntax.EqualsValueClause(
                                                Syntax.LiteralExpression(
                                                    SyntaxKind.NumericLiteralExpression,
                                                    Syntax.Literal(
                                                        Syntax.TriviaList(),
                                                        @"1",
                                                        1,
                                                        Syntax.TriviaList())))
                                            .WithEqualsToken(
                                                Syntax.Token(
                                                    SyntaxKind.EqualsToken,
                                                    Syntax.TriviaList(
                                                        Syntax.Space)))))))
                            .WithSemicolonToken(
                                Syntax.Token(
                                    SyntaxKind.SemicolonToken))))
                    .WithEndOfFileToken(
                        Syntax.Token(
                            SyntaxKind.EndOfFileToken))
    AreEqual      : True