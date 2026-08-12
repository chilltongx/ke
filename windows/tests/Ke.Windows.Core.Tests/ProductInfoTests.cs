using Ke.Windows.Core;
using Xunit;

namespace Ke.Windows.Core.Tests;

public sealed class ProductInfoTests
{
    [Fact]
    public void Product_identity_is_fixed()
    {
        Assert.Equal("可", ProductInfo.ProductName);
        Assert.Equal("可", ProductInfo.ApprovalText);
    }
}
