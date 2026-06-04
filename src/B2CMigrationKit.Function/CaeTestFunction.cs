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
/// Test endpoints that simulate Custom Authentication Extension (CAE) backends for External ID.
///
/// External ID calls these endpoints using Azure AD bearer token authentication
/// (unlike B2C API Connectors which use Basic Auth / API Key).
///
/// Two events are covered:
///
///   POST /api/CaeTokenIssuanceTest
///     Equivalent to B2C "Before including application claims in token".
///     External ID event: onTokenIssuanceStart
///     Returns extra claims merged into the issued token.
///
///   POST /api/CaeAttributeCollectionTest
///     Equivalent to B2C "Before creating the user".
///     External ID event: onAttributeCollectionSubmit
///     Can continue, modify attributes, show validation errors, or block.
///
/// Authentication:
///   External ID sends: Authorization: Bearer &lt;Azure AD token&gt;
///   The audience of the token must match the CAE app's identifierUri
///   (set in CaeTest__ExpectedAudience in local.settings.json).
///   If CaeTest__ExpectedAudience is empty, audience check is skipped (dev only).
///
/// Setup:
///   1. Run Import-EeidApps.ps1 to create the CAE resources in External ID.
///   2. Copy the printed resourceId into CaeTest__ExpectedAudience in local.settings.json.
///   3. Start the function and forward port 7071 via VS Code → set Public.
///   4. Use the public URL as the targetUrl in the CAE (via Azure Portal or the import script).
/// </summary>
public class CaeTestFunction
{
    private readonly ILogger<CaeTestFunction> _logger;
    private readonly string? _expectedAudience;

    private static readonly JsonSerializerOptions _jsonOptions = new()
    {
        PropertyNameCaseInsensitive = true,
        WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull
    };

    public CaeTestFunction(ILogger<CaeTestFunction> logger)
    {
        _logger = logger;
        _expectedAudience = Environment.GetEnvironmentVariable("CaeTest__ExpectedAudience");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  onTokenIssuanceStart  —  adds extra claims to the issued token
    // ═══════════════════════════════════════════════════════════════════════════

    [Function("CaeTokenIssuanceTest")]
    public async Task<HttpResponseData> TokenIssuanceAsync(
        [HttpTrigger(AuthorizationLevel.Anonymous, "post", "get")] HttpRequestData req,
        FunctionContext context)
    {
        _logger.LogInformation("[CaeTokenIssuanceTest] {Method} {Url}", req.Method, req.Url);

        if (req.Method.Equals("GET", StringComparison.OrdinalIgnoreCase))
        {
            var ping = req.CreateResponse(HttpStatusCode.OK);
            await ping.WriteStringAsync("CAE onTokenIssuanceStart Test Endpoint - Ready");
            return ping;
        }

        // ── Validate bearer token ─────────────────────────────────────────────
        var (authOk, authError, tokenClaims) = ValidateBearerToken(req);
        if (!authOk)
        {
            _logger.LogWarning("[CaeTokenIssuanceTest] Unauthorized: {Error}", authError);
            return await UnauthorizedResponse(req, authError!);
        }

        _logger.LogInformation("[CaeTokenIssuanceTest] Token claims — sub: {Sub} | aud: {Aud}",
            tokenClaims.GetValueOrDefault("sub"), tokenClaims.GetValueOrDefault("aud"));

        // ── Parse External ID payload ─────────────────────────────────────────
        var body = await new StreamReader(req.Body).ReadToEndAsync();
        _logger.LogInformation("[CaeTokenIssuanceTest] Payload:\n{Body}", body);

        CaeRequest? caeReq = null;
        try { caeReq = JsonSerializer.Deserialize<CaeRequest>(body, _jsonOptions); }
        catch (JsonException ex) { _logger.LogError(ex, "[CaeTokenIssuanceTest] Failed to parse body"); }

        var userId = caeReq?.Data?.AuthenticationContext?.User?.Id ?? "(unknown)";
        var upn    = caeReq?.Data?.AuthenticationContext?.User?.UserPrincipalName ?? "(unknown)";

        _logger.LogInformation("[CaeTokenIssuanceTest] User: {Upn} ({Id})", upn, userId);

        // ── Return test claims ────────────────────────────────────────────────
        // These claims will be merged into the token issued to the application.
        // Add/rename to match the claims your real API will provide.
        // Register them in claimsForTokenConfiguration on the CAE via Azure Portal.
        var response = new TokenIssuanceResponse
        {
            Data = new TokenIssuanceResponseData
            {
                Actions = new[]
                {
                    new ProvideClaimsAction
                    {
                        Claims = new Dictionary<string, object>
                        {
                            ["caeTestFlag"]     = "token-issuance-test-passed",
                            ["caeProcessedAt"]  = DateTimeOffset.UtcNow.ToString("o"),
                            ["caeUserId"]       = userId
                        }
                    }
                }
            }
        };

        _logger.LogInformation("[CaeTokenIssuanceTest] Returning claims for user {Upn}", upn);

        var httpResponse = req.CreateResponse(HttpStatusCode.OK);
        httpResponse.Headers.Add("Content-Type", "application/json");
        await httpResponse.WriteStringAsync(JsonSerializer.Serialize(response, _jsonOptions));
        return httpResponse;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  onAttributeCollectionSubmit  —  validates / modifies sign-up attributes
    // ═══════════════════════════════════════════════════════════════════════════

    [Function("CaeAttributeCollectionTest")]
    public async Task<HttpResponseData> AttributeCollectionAsync(
        [HttpTrigger(AuthorizationLevel.Anonymous, "post", "get")] HttpRequestData req,
        FunctionContext context)
    {
        _logger.LogInformation("[CaeAttributeCollectionTest] {Method} {Url}", req.Method, req.Url);

        if (req.Method.Equals("GET", StringComparison.OrdinalIgnoreCase))
        {
            var ping = req.CreateResponse(HttpStatusCode.OK);
            await ping.WriteStringAsync("CAE onAttributeCollectionSubmit Test Endpoint - Ready");
            return ping;
        }

        // ── Validate bearer token ─────────────────────────────────────────────
        var (authOk, authError, tokenClaims) = ValidateBearerToken(req);
        if (!authOk)
        {
            _logger.LogWarning("[CaeAttributeCollectionTest] Unauthorized: {Error}", authError);
            return await UnauthorizedResponse(req, authError!);
        }

        // ── Parse payload ─────────────────────────────────────────────────────
        var body = await new StreamReader(req.Body).ReadToEndAsync();
        _logger.LogInformation("[CaeAttributeCollectionTest] Payload:\n{Body}", body);

        CaeRequest? caeReq = null;
        try { caeReq = JsonSerializer.Deserialize<CaeRequest>(body, _jsonOptions); }
        catch (JsonException ex) { _logger.LogError(ex, "[CaeAttributeCollectionTest] Failed to parse body"); }

        var upn        = caeReq?.Data?.AuthenticationContext?.User?.UserPrincipalName ?? "(unknown)";
        var attributes = caeReq?.Data?.UserSignUpInfo?.Attributes;

        _logger.LogInformation("[CaeAttributeCollectionTest] User: {Upn} | Attributes received: {Count}",
            upn, attributes?.Count ?? 0);

        if (attributes != null)
        {
            foreach (var attr in attributes)
                _logger.LogInformation("[CaeAttributeCollectionTest]   {Key} = {Value}", attr.Key, attr.Value);
        }

        // ── Return: continue with default behavior ────────────────────────────
        // Change the @odata.type to modify attributes or block the user:
        //
        //   Continue (no changes):
        //     "microsoft.graph.attributeCollectionSubmit.continueWithDefaultBehavior"
        //
        //   Modify attribute values before user creation:
        //     "microsoft.graph.attributeCollectionSubmit.modifyAttributeValues"
        //     + "attributes": { "city": "Modified City" }
        //
        //   Validation error (shown inline on the sign-up form):
        //     "microsoft.graph.attributeCollectionSubmit.showValidationError"
        //     + "message": "City must be a valid value."
        //     + "attributesToValidate": ["city"]
        //
        //   Block entirely:
        //     "microsoft.graph.attributeCollectionSubmit.blockAndShowErrorMessage"
        //     + "message": "Registration is not allowed."

        var response = new AttributeCollectionResponse
        {
            Data = new AttributeCollectionResponseData
            {
                Actions = new[]
                {
                    new AttributeCollectionAction
                    {
                        ODataType = "microsoft.graph.attributeCollectionSubmit.continueWithDefaultBehavior"
                    }
                }
            }
        };

        _logger.LogInformation("[CaeAttributeCollectionTest] Returning: continueWithDefaultBehavior for {Upn}", upn);

        var httpResponse = req.CreateResponse(HttpStatusCode.OK);
        httpResponse.Headers.Add("Content-Type", "application/json");
        await httpResponse.WriteStringAsync(JsonSerializer.Serialize(response, _jsonOptions));
        return httpResponse;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  Shared helpers
    // ═══════════════════════════════════════════════════════════════════════════

    /// <summary>
    /// Checks for a Bearer token and optionally validates the audience.
    /// Full cryptographic validation is intentionally omitted for this test endpoint.
    /// In production, use Microsoft.Identity.Web or IdentityModel to validate fully.
    /// </summary>
    private (bool ok, string? error, Dictionary<string, string> claims) ValidateBearerToken(HttpRequestData req)
    {
        var empty = new Dictionary<string, string>();

        if (!req.Headers.TryGetValues("Authorization", out var authValues))
            return (false, "Missing Authorization header. External ID CAEs require a Bearer token.", empty);

        var authHeader = authValues.FirstOrDefault();
        if (authHeader == null || !authHeader.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase))
            return (false, "Authorization header must use Bearer scheme.", empty);

        var token = authHeader["Bearer ".Length..].Trim();
        if (string.IsNullOrEmpty(token))
            return (false, "Bearer token is empty.", empty);

        // Decode claims from JWT payload (no signature validation — test only)
        var claims = DecodeJwtClaims(token);

        // Audience check (only if CaeTest__ExpectedAudience is configured)
        if (!string.IsNullOrEmpty(_expectedAudience))
        {
            var aud = claims.GetValueOrDefault("aud") ?? string.Empty;
            if (!aud.Equals(_expectedAudience, StringComparison.OrdinalIgnoreCase))
            {
                _logger.LogWarning("[CAE] Audience mismatch — got: {Got} | expected: {Expected}", aud, _expectedAudience);
                return (false, $"Token audience '{aud}' does not match expected '{_expectedAudience}'.", claims);
            }
        }
        else
        {
            _logger.LogWarning("[CAE] CaeTest__ExpectedAudience not set — skipping audience validation (dev only)");
        }

        return (true, null, claims);
    }

    private static Dictionary<string, string> DecodeJwtClaims(string token)
    {
        try
        {
            var parts = token.Split('.');
            if (parts.Length < 2) return new();
            var payload = parts[1];
            // Fix base64url padding
            payload = payload.Replace('-', '+').Replace('_', '/');
            switch (payload.Length % 4)
            {
                case 2: payload += "=="; break;
                case 3: payload += "=";  break;
            }
            var json = System.Text.Encoding.UTF8.GetString(Convert.FromBase64String(payload));
            var doc  = JsonDocument.Parse(json);
            return doc.RootElement.EnumerateObject()
                .ToDictionary(p => p.Name, p => p.Value.ToString());
        }
        catch
        {
            return new();
        }
    }

    private static async Task<HttpResponseData> UnauthorizedResponse(HttpRequestData req, string message)
    {
        var response = req.CreateResponse(HttpStatusCode.Unauthorized);
        response.Headers.Add("Content-Type", "application/json");
        await response.WriteStringAsync(JsonSerializer.Serialize(new
        {
            error = "unauthorized",
            message
        }));
        return response;
    }
}

// ── CAE request models ────────────────────────────────────────────────────────

public class CaeRequest
{
    [JsonPropertyName("type")]
    public string? Type { get; set; }

    [JsonPropertyName("data")]
    public CaeRequestData? Data { get; set; }
}

public class CaeRequestData
{
    [JsonPropertyName("tenantId")]
    public string? TenantId { get; set; }

    [JsonPropertyName("authenticationContext")]
    public CaeAuthContext? AuthenticationContext { get; set; }

    // onAttributeCollectionSubmit only
    [JsonPropertyName("userSignUpInfo")]
    public UserSignUpInfo? UserSignUpInfo { get; set; }
}

public class CaeAuthContext
{
    [JsonPropertyName("correlationId")]
    public string? CorrelationId { get; set; }

    [JsonPropertyName("user")]
    public CaeUserInfo? User { get; set; }

    [JsonPropertyName("clientServicePrincipal")]
    public CaeServicePrincipal? ClientServicePrincipal { get; set; }
}

public class CaeUserInfo
{
    [JsonPropertyName("id")]
    public string? Id { get; set; }

    [JsonPropertyName("displayName")]
    public string? DisplayName { get; set; }

    [JsonPropertyName("userPrincipalName")]
    public string? UserPrincipalName { get; set; }

    [JsonPropertyName("mail")]
    public string? Mail { get; set; }
}

public class CaeServicePrincipal
{
    [JsonPropertyName("appDisplayName")]
    public string? AppDisplayName { get; set; }

    [JsonPropertyName("appId")]
    public string? AppId { get; set; }
}

public class UserSignUpInfo
{
    [JsonPropertyName("attributes")]
    public Dictionary<string, JsonElement>? Attributes { get; set; }

    [JsonPropertyName("identities")]
    public List<UserIdentity>? Identities { get; set; }
}

public class UserIdentity
{
    [JsonPropertyName("signInType")]
    public string? SignInType { get; set; }

    [JsonPropertyName("issuerAssignedId")]
    public string? IssuerAssignedId { get; set; }
}

// ── onTokenIssuanceStart response models ─────────────────────────────────────

public class TokenIssuanceResponse
{
    [JsonPropertyName("data")]
    public TokenIssuanceResponseData Data { get; set; } = new();
}

public class TokenIssuanceResponseData
{
    [JsonPropertyName("@odata.type")]
    public string ODataType { get; set; } = "microsoft.graph.onTokenIssuanceStartResponseData";

    [JsonPropertyName("actions")]
    public ProvideClaimsAction[] Actions { get; set; } = Array.Empty<ProvideClaimsAction>();
}

public class ProvideClaimsAction
{
    [JsonPropertyName("@odata.type")]
    public string ODataType { get; set; } = "microsoft.graph.tokenIssuanceStart.provideClaimsForToken";

    [JsonPropertyName("claims")]
    public Dictionary<string, object> Claims { get; set; } = new();
}

// ── onAttributeCollectionSubmit response models ───────────────────────────────

public class AttributeCollectionResponse
{
    [JsonPropertyName("data")]
    public AttributeCollectionResponseData Data { get; set; } = new();
}

public class AttributeCollectionResponseData
{
    [JsonPropertyName("@odata.type")]
    public string ODataType { get; set; } = "microsoft.graph.onAttributeCollectionSubmitResponseData";

    [JsonPropertyName("actions")]
    public AttributeCollectionAction[] Actions { get; set; } = Array.Empty<AttributeCollectionAction>();
}

public class AttributeCollectionAction
{
    [JsonPropertyName("@odata.type")]
    public string ODataType { get; set; } = "microsoft.graph.attributeCollectionSubmit.continueWithDefaultBehavior";

    // Used with modifyAttributeValues
    [JsonPropertyName("attributes")]
    public Dictionary<string, object>? Attributes { get; set; }

    // Used with showValidationError
    [JsonPropertyName("message")]
    public string? Message { get; set; }

    [JsonPropertyName("attributesToValidate")]
    public string[]? AttributesToValidate { get; set; }
}
