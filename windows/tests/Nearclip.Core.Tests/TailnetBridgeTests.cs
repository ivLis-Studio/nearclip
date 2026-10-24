using Xunit;

namespace Nearclip.Core.Tests;

/// <summary>The GODEBUG setting added for x64 builds emulated on ARM64 Windows (TailnetBridge).</summary>
public sealed class TailnetBridgeTests
{
    [Theory]
    [InlineData(null, "asyncpreemptoff=1")]
    [InlineData("", "asyncpreemptoff=1")]
    [InlineData("http2client=0", "http2client=0,asyncpreemptoff=1")]
    [InlineData("asyncpreemptoff=0", "asyncpreemptoff=0")]
    [InlineData("gctrace=1, asyncpreemptoff=0", "gctrace=1, asyncpreemptoff=0")]
    public void MergeGoDebugKeepsWhatIsSet(string? current, string expected) =>
        Assert.Equal(expected, TailnetBridge.MergeGoDebug(current, "asyncpreemptoff=1"));
}
