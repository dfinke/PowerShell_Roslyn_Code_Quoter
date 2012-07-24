# requires -version 3

param(
    $sourceText = 'using x;'
)

. .\CompileEvaluator.ps1
. .\CompileQuoter.ps1

$generatedCode = New-Object Quoter

$generatedCode.ClosingParenthesisOnNewLine = $false
$generatedCode.OpenParenthesisOnNewLine = $false

$code = $generatedCode.Quote($sourceText)

$evaluator = New-Object Evaluator
$generatedNode = $evaluator.Evaluate($code)
$evaluated = $generatedNode.GetFullText()

[PSCustomObject] @{
    Source          = $sourceText
    Evaluated       = $evaluated 
    GeneratedCode   = $code
} | Add-Member -PassThru ScriptProperty AreEqual { $this.Source -ceq $this.Evaluated} 
