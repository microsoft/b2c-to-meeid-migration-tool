// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Http;
using Microsoft.Extensions.Logging;
using System.Net;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace B2CMigrationKit.Function;

/// <summary>
/// Test endpoint that simulates a B2C API Connector backend.
///
/// B2C calls this endpoint at:
///   - PostFederationSignup  (after federation, before user is created)
///   - PostAttributeCollection (after sign-up attributes are collected)
///
/// The endpoint echoes back the incoming claims and adds a set of
/// hard-coded test claims so you can verify the full round-trip without
/// needing a real backend.
///
/// Authentication: B2C API Connectors support Basic Auth or API Key.
/// This test endpoint accepts an optional API key via the
/// "x-api-key" header or "apiKey" query parameter.  Leave
/// ApiConnectorTest__ApiKey blank in local.settings.json to disable auth.
///
/// Usage:
///   1. Start the function:  cd src/B2CMigrationKit.Function; func start
///   2. Forward port 7071 via VS Code (Ports panel) and set visibility to Public.
///   3. Use the public devtunnel URL as the Endpoint URL in the B2C API Connector:
///        https://&lt;tunnel-host&gt;/api/ApiConnectorTest
///   4. Configure the B2C User Flow to call this connector at the desired step.
///   5. Trigger a sign-up flow and inspect the function logs.
/// </summary>
public class ApiConnectorTestFunction
{
    private readonly ILogger<ApiConnectorTestFunction> _logger;

    // Optional API key read from configuration (env var ApiConnectorTest__ApiKey).
    // Set in local.settings.json → Values → "ApiConnectorTest__ApiKey": "my-secret-key"
    private readonly string? _configuredApiKey;

    private static readonly JsonSerializerOptions _jsonOptions = new()
    {
        PropertyNameCaseInsensitive = true,
        WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull
    };

    public ApiConnectorTestFunction(ILogger<ApiConnectorTestFunction> logger)
    {
        _logger = logger;
        _configuredApiKey = Environment.GetEnvironmentVariable("ApiConnectorTest__ApiKey");
    }

    [Function("ApiConnectorTest")]
    public async Task<HttpResponseData> RunAsync(
        [HttpTrigger(AuthorizationLevel.Anonymous, "post", "get")] HttpRequestData req,
        FunctionContext context)
    {
        _logger.LogInformation("[ApiConnectorTest] {Method} {Url}", req.Method, req.Url);

        // GET — endpoint validation ping from Azure Portal / B2C
        if (req.Method.Equals("GET", StringComparison.OrdinalIgnoreCase))
        {
            var ok = req.CreateResponse(HttpStatusCode.OK);
            await ok.WriteStringAsync("B2C API Connector Test Endpoint - Ready");
            return ok;
        }

        // ── Optional API key check ────────────────────────────────────────────
        // Accepts:
        //   - x-api-key header (for manual curl tests)
        //   - Authorization: Basic <base64(user:password)> where password = ApiKey
        //     (this is how B2C API connectors authenticate via Graph API)
        if (!string.IsNullOrEmpty(_configuredApiKey))
        {
            var providedKey = GetApiKey(req);
            if (!string.Equals(providedKey, _configuredApiKey, StringComparison.Ordinal))
            {
                _logger.LogWarning("[ApiConnectorTest] Unauthorized - invalid or missing API key");
                var unauthorized = req.CreateResponse(HttpStatusCode.Unauthorized);
                unauthorized.Headers.Add("Content-Type", "application/json");
                await unauthorized.WriteStringAsync(JsonSerializer.Serialize(new B2CApiConnectorResponse
                {
                    Version = "1.0.0",
                    Status = 401,
                    UserMessage = "Unauthorized. Provide a valid API key."
                }, _jsonOptions));
                return unauthorized;
            }
        }

        // ── Parse incoming B2C payload ────────────────────────────────────────
        var body = await new StreamReader(req.Body).ReadToEndAsync();

        _logger.LogInformation("[ApiConnectorTest] Incoming payload:\n{Body}", body);

        B2CApiConnectorRequest? incomingClaims = null;
        try
        {
            incomingClaims = JsonSerializer.Deserialize<B2CApiConnectorRequest>(body, _jsonOptions);
        }
        catch (JsonException ex)
        {
            _logger.LogError(ex, "[ApiConnectorTest] Failed to deserialize request body");
        }

        var step = incomingClaims?.Step ?? "unknown";
        var email = incomingClaims?.Email ?? incomingClaims?.SignInNames_EmailAddress ?? "(no email)";
        var displayName = incomingClaims?.DisplayName ?? "(no displayName)";

        _logger.LogInformation(
            "[ApiConnectorTest] Step={Step} | Email={Email} | DisplayName={DisplayName}",
            step, email, displayName);

        // ── Build response with test claims ───────────────────────────────────
        // These extra claims will be merged into the token / user object by B2C.
        // Customize these to match the claims your real API would return.
        var response = new B2CApiConnectorResponse
        {
            Version = "1.0.0",
            Status = 200,

            // ── Test claims returned to B2C ────────────────────────────────
            // Add or rename these to match your B2C policy's output claims.
            Extension_MigrationTestFlag = "connector-test-passed",
            Extension_ProcessedStep = step,
            Extension_ProcessedAt = DateTimeOffset.UtcNow.ToString("o")
        };

        _logger.LogInformation(
            "[ApiConnectorTest] Returning test claims: MigrationTestFlag={Flag} | Step={Step}",
            response.Extension_MigrationTestFlag, response.Extension_ProcessedStep);

        var httpResponse = req.CreateResponse(HttpStatusCode.OK);
        httpResponse.Headers.Add("Content-Type", "application/json");
        await httpResponse.WriteStringAsync(JsonSerializer.Serialize(response, _jsonOptions));
        return httpResponse;
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    /// <summary>Extracts API key from x-api-key header, apiKey query param, or Basic Auth password.</summary>
    private static string? GetApiKey(HttpRequestData req)
    {
        // 1. x-api-key header (manual curl / direct tests)
        if (req.Headers.TryGetValues("x-api-key", out var headerValues))
            return headerValues.FirstOrDefault();

        // 2. Basic Auth — B2C API connectors send: Authorization: Basic base64(username:password)
        //    We treat the password field as the API key (username is ignored).
        if (req.Headers.TryGetValues("Authorization", out var authValues))
        {
            var authHeader = authValues.FirstOrDefault();
            if (authHeader != null && authHeader.StartsWith("Basic ", StringComparison.OrdinalIgnoreCase))
            {
                try
                {
                    var decoded = System.Text.Encoding.UTF8.GetString(
                        Convert.FromBase64String(authHeader["Basic ".Length..].Trim()));
                    var colon = decoded.IndexOf(':');
                    if (colon >= 0)
                        return decoded[(colon + 1)..];
                }
                catch { /* malformed base64 — fall through */ }
            }
        }

        // 3. apiKey query parameter (fallback)
        var query = System.Web.HttpUtility.ParseQueryString(req.Url.Query);
        return query["apiKey"];
    }
}

// ── B2C API Connector request model ──────────────────────────────────────────
// B2C sends a flat JSON object with all current claims.
// Only the fields most commonly present are mapped; the rest land in AdditionalClaims.

public class B2CApiConnectorRequest
{
    [JsonPropertyName("step")]
    public string? Step { get; set; }

    [JsonPropertyName("email")]
    public string? Email { get; set; }

    // B2C sometimes uses this name for email
    [JsonPropertyName("signInNames.emailAddress")]
    public string? SignInNames_EmailAddress { get; set; }

    [JsonPropertyName("displayName")]
    public string? DisplayName { get; set; }

    [JsonPropertyName("givenName")]
    public string? GivenName { get; set; }

    [JsonPropertyName("surname")]
    public string? Surname { get; set; }

    [JsonPropertyName("objectId")]
    public string? ObjectId { get; set; }

    [JsonPropertyName("ui_locales")]
    public string? UiLocales { get; set; }

    [JsonPropertyName("client_id")]
    public string? ClientId { get; set; }

    // Catch-all for any extra claims B2C sends
    [JsonExtensionData]
    public Dictionary<string, JsonElement>? AdditionalClaims { get; set; }
}

// ── B2C API Connector response model ─────────────────────────────────────────
// B2C merges any extra properties returned here into the token claims.
// Rename extension_ properties to match your B2C policy output claims.

public class B2CApiConnectorResponse
{
    [JsonPropertyName("version")]
    public string Version { get; set; } = "1.0.0";

    [JsonPropertyName("status")]
    public int Status { get; set; } = 200;

    // Optional: shown to the user if Status != 200
    [JsonPropertyName("userMessage")]
    public string? UserMessage { get; set; }

    // ── Test claims ───────────────────────────────────────────────────────────
    // These must match output claims declared in your B2C user flow / custom policy.

    [JsonPropertyName("extension_migrationTestFlag")]
    public string? Extension_MigrationTestFlag { get; set; }

    [JsonPropertyName("extension_processedStep")]
    public string? Extension_ProcessedStep { get; set; }

    [JsonPropertyName("extension_processedAt")]
    public string? Extension_ProcessedAt { get; set; }
}
