using System.Net;
using eShop.ServiceDefaults;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.TestHost;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Hosting;
using ServiceDefaultsExtensions = eShop.ServiceDefaults.Extensions;

namespace eShop.Application.UnitTests;

[TestClass]
public class ServiceDefaultsHealthEndpointTests
{
    public TestContext TestContext { get; set; } = null!;

    [TestMethod]
    [DataRow("/health")]
    [DataRow("/alive")]
    public async Task HealthEndpointsAreNotMappedInProductionByDefault(string path)
    {
        var status = await GetStatusAsync(Environments.Production, path);

        Assert.AreEqual(HttpStatusCode.NotFound, status);
    }

    [TestMethod]
    [DataRow("/health")]
    [DataRow("/alive")]
    public async Task HealthEndpointsAreMappedInProductionWhenEnvironmentKeyIsTrue(string path)
    {
        var status = await GetStatusAsync(
            Environments.Production,
            path,
            new KeyValuePair<string, string?>(ServiceDefaultsExtensions.ExposeHealthEndpointsEnvironmentKey, "true"));

        Assert.AreEqual(HttpStatusCode.OK, status);
    }

    [TestMethod]
    [DataRow("/health")]
    [DataRow("/alive")]
    public async Task HealthEndpointsAreMappedInProductionWhenConfigurationKeyIsTrue(string path)
    {
        var status = await GetStatusAsync(
            Environments.Production,
            path,
            new KeyValuePair<string, string?>(ServiceDefaultsExtensions.ExposeHealthEndpointsConfigurationKey, "true"));

        Assert.AreEqual(HttpStatusCode.OK, status);
    }

    [TestMethod]
    [DataRow("/health")]
    [DataRow("/alive")]
    public async Task HealthEndpointsAreMappedInDevelopmentWithoutSwitch(string path)
    {
        var status = await GetStatusAsync(Environments.Development, path);

        Assert.AreEqual(HttpStatusCode.OK, status);
    }

    [TestMethod]
    [DataRow(ServiceDefaultsExtensions.ExposeHealthEndpointsEnvironmentKey, "not-a-bool")]
    [DataRow(ServiceDefaultsExtensions.ExposeHealthEndpointsEnvironmentKey, "")]
    [DataRow(ServiceDefaultsExtensions.ExposeHealthEndpointsEnvironmentKey, "false")]
    [DataRow(ServiceDefaultsExtensions.ExposeHealthEndpointsConfigurationKey, "not-a-bool")]
    [DataRow(ServiceDefaultsExtensions.ExposeHealthEndpointsConfigurationKey, "1")]
    [DataRow(ServiceDefaultsExtensions.ExposeHealthEndpointsConfigurationKey, "false")]
    public async Task HealthEndpointsAreNotMappedInProductionWhenSwitchIsInvalidOrFalse(string key, string value)
    {
        foreach (var path in new[] { "/health", "/alive" })
        {
            var status = await GetStatusAsync(
                Environments.Production,
                path,
                new KeyValuePair<string, string?>(key, value));

            Assert.AreEqual(HttpStatusCode.NotFound, status, $"{path} should not be mapped for {key}='{value}'.");
        }
    }

    private async Task<HttpStatusCode> GetStatusAsync(
        string environmentName,
        string path,
        params KeyValuePair<string, string?>[] configuration)
    {
        var builder = WebApplication.CreateBuilder(new WebApplicationOptions
        {
            EnvironmentName = environmentName
        });
        builder.WebHost.UseTestServer();
        builder.Configuration.AddInMemoryCollection(configuration);
        builder.AddDefaultHealthChecks();

        await using var app = builder.Build();
        app.MapDefaultEndpoints();
        await app.StartAsync(TestContext.CancellationToken);

        try
        {
            using var client = app.GetTestClient();
            using var response = await client.GetAsync(path, TestContext.CancellationToken);
            return response.StatusCode;
        }
        finally
        {
            await app.StopAsync(TestContext.CancellationToken);
        }
    }
}
