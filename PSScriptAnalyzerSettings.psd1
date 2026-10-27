@{
    # These scripts are run by an operator in an interactive console, where
    # Write-Host is the intended way to show progress. The rule targets
    # reusable functions whose output callers need to capture.
    ExcludeRules = @('PSAvoidUsingWriteHost')
}
