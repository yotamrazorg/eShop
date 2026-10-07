using System.Text.RegularExpressions;
using Aspire.Hosting;
using Aspire.Hosting.ApplicationModel;
using Aspire.Hosting.Dotnet;
using Aspire.Hosting.Eventing;
using Aspire.Hosting.Lifecycle;
using eShop.AppHost;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;

namespace eShop.AppHost.UnitTests;

[TestClass]
public class AppHostConfigurationTests
{
    public TestContext TestContext { get; set; } = null!;

    [TestMethod]
    public async Task ForwardedHeadersExtensionConfiguresDotnetProjectsOnly()
    {
        var builder = CreateBuilder();
        builder.Services.RemoveAll<IDistributedApplicationEventingSubscriber>();
        builder.AddForwardedHeaders();
        var catalog = builder.AddDotnetProject("catalog-api", ProjectPath("Catalog.API", "Catalog.API.csproj"));
        var webApp = builder.AddDotnetProject("webapp", ProjectPath("WebApp", "WebApp.csproj"));
        var redis = builder.AddRedis("redis");
        var annotationCounts = builder.Resources.ToDictionary(resource => resource, resource => resource.Annotations.Count);

        using var services = builder.Services.BuildServiceProvider();
        var eventing = new DistributedApplicationEventing();
        foreach (var subscriber in services.GetServices<IDistributedApplicationEventingSubscriber>())
        {
            await subscriber.SubscribeAsync(eventing, builder.ExecutionContext, TestContext.CancellationToken);
        }

        var model = services.GetRequiredService<DistributedApplicationModel>();
        await eventing.PublishAsync(new BeforeStartEvent(services, model), TestContext.CancellationToken);

        foreach (var project in new[] { catalog.Resource, webApp.Resource })
        {
            var annotation = project.Annotations.Skip(annotationCounts[project])
                .OfType<EnvironmentCallbackAnnotation>().Single();
            var context = new EnvironmentCallbackContext(builder.ExecutionContext, project, cancellationToken: TestContext.CancellationToken);
            await annotation.Callback(context);

            Assert.AreEqual("true", context.EnvironmentVariables["ASPNETCORE_FORWARDEDHEADERS_ENABLED"]);
        }

        Assert.HasCount(annotationCounts[redis.Resource], redis.Resource.Annotations);
    }

    [TestMethod]
    [DataRow(null, false)]
    [DataRow("", false)]
    [DataRow("invalid", false)]
    [DataRow("false", false)]
    [DataRow("true", true)]
    public void FoundryFlagUsesSafeOptInDefault(string? configuredValue, bool expected)
    {
        var configuration = new ConfigurationBuilder()
            .AddInMemoryCollection(new Dictionary<string, string?> { ["UseFoundry"] = configuredValue })
            .Build();

        Assert.AreEqual(expected, Extensions.IsFoundryEnabled(configuration));
    }

    [TestMethod]
    public void FoundryExtensionAddsExpectedDeployments()
    {
        var builder = CreateBuilder();
        var catalog = builder.AddDotnetProject("catalog-api", ProjectPath("Catalog.API", "Catalog.API.csproj"));
        var webApp = builder.AddDotnetProject("webapp", ProjectPath("WebApp", "WebApp.csproj"));

        builder.AddFoundry(catalog, webApp);

        CollectionAssert.IsSubsetOf(
            new[] { "foundry", "chatModel", "textEmbeddingModel" },
            builder.Resources.Select(resource => resource.Name).ToArray());
    }

    [TestMethod]
    public void OllamaExtensionAddsExpectedModels()
    {
        var builder = CreateBuilder();
        var catalog = builder.AddDotnetProject("catalog-api", ProjectPath("Catalog.API", "Catalog.API.csproj"));
        var webApp = builder.AddDotnetProject("webapp", ProjectPath("WebApp", "WebApp.csproj"));

        builder.AddOllama(catalog, webApp);

        CollectionAssert.IsSubsetOf(
            new[] { "ollama", "embedding", "chat" },
            builder.Resources.Select(resource => resource.Name).ToArray());
    }

    [TestMethod]
    public void IdentityConnectionNameMatchesAppHostAndDeployDatabases()
    {
        var root = FindRepositoryRoot();

        var program = File.ReadAllText(Path.Combine(root, "src", "Identity.API", "Program.cs"));
        var match = Regex.Match(program, "AddNpgsqlDbContext<ApplicationDbContext>\\(\"(?<name>[^\"]+)\"\\)");
        Assert.IsTrue(match.Success, "Identity.API/Program.cs no longer registers ApplicationDbContext by connection name.");
        var name = match.Groups["name"].Value;

        var appHost = File.ReadAllText(Path.Combine(root, "src", "eShop.AppHost", "AppHost.cs"));
        StringAssert.Contains(appHost, $"AddDatabase(\"{name}\")");

        var postgresStep = File.ReadAllText(Path.Combine(root, "deploy", "ubuntu", "lib", "steps-postgres.sh"));
        var databases = Regex.Match(postgresStep, @"^ESHOP_PG_DATABASES=\((?<list>[^)]*)\)", RegexOptions.Multiline);
        Assert.IsTrue(databases.Success, "ESHOP_PG_DATABASES not found in steps-postgres.sh.");
        CollectionAssert.Contains(databases.Groups["list"].Value.Split(' ', StringSplitOptions.RemoveEmptyEntries), name);
    }

    private static IDistributedApplicationBuilder CreateBuilder() =>
        DistributedApplication.CreateBuilder(new DistributedApplicationOptions
        {
            AssemblyName = typeof(AppHostConfigurationTests).Assembly.FullName,
            DisableDashboard = true
        });

    private static string ProjectPath(string directory, string project) =>
        Path.Combine(FindRepositoryRoot(), "src", directory, project);

    private static string FindRepositoryRoot()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null && !File.Exists(Path.Combine(directory.FullName, "eShop.slnx")))
        {
            directory = directory.Parent;
        }

        return directory?.FullName
            ?? throw new DirectoryNotFoundException("Could not locate the eShop repository root.");
    }
}
