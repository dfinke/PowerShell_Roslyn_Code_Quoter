$referencedAssemblies = .\ReferencedAssemblies.ps1

Add-Type -ReferencedAssemblies $referencedAssemblies @"
public class Evaluator
{
    private Roslyn.Scripting.CSharp.ScriptEngine engine;
    private Roslyn.Scripting.Session session;

    public Evaluator()
    {
        engine = new Roslyn.Scripting.CSharp.ScriptEngine(
            importedNamespaces: new[] { "Roslyn.Compilers", "Roslyn.Compilers.CSharp" });

        CreateSession();
    }

    private void CreateSession()
    {
        session = Roslyn.Scripting.Session.Create();
        session.AddReference(typeof(Roslyn.Compilers.Common.CommonSyntaxNode).Assembly);
        session.AddReference(typeof(Roslyn.Compilers.CSharp.SyntaxNode).Assembly);
    }

    public object Evaluate(string code)
    {
        var result = engine.Execute(code, session);
        return result;
    }
}
"@
