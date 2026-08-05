using Ke.Windows.Core;
using Xunit;

namespace Ke.Windows.Core.Tests;

public sealed class TargetIdentityTests
{
    [Fact]
    public void Target_identity_includes_window_process_runtime_id_and_app()
    {
        var a = new TargetIdentity((nint)1, 2, "42.7", SupportedApplication.Codex);
        Assert.NotEqual(a, a with { RuntimeId = "42.8" });
        Assert.NotEqual(a, a with { Application = SupportedApplication.VisualStudioCode });
    }

    [Fact]
    public void Send_result_expresses_success_or_specific_failure()
    {
        Assert.Equal(new SendResult(true, null), SendResult.Success());
        Assert.Equal(
            new SendResult(false, SendErrorCode.TargetChanged),
            SendResult.Failure(SendErrorCode.TargetChanged));
    }
}
