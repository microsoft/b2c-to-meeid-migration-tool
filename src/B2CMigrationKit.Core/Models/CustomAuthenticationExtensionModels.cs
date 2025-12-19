// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
using System.Text.Json.Serialization;

namespace B2CMigrationKit.Core.Models;

/// <summary>
/// Request payload from External ID Custom Authentication Extension (OnPasswordSubmit event).
/// </summary>
public class CustomAuthenticationExtensionRequest
{
    [JsonPropertyName("data")]
    public RequestData? Data { get; set; }
}

public class RequestData
{
    [JsonPropertyName("@odata.type")]
    public string? ODataType { get; set; }

    [JsonPropertyName("tenantId")]
    public string? TenantId { get; set; }

    [JsonPropertyName("authenticationEventListenerId")]
    public string? AuthenticationEventListenerId { get; set; }

    [JsonPropertyName("customAuthenticationExtensionId")]
    public string? CustomAuthenticationExtensionId { get; set; }

    [JsonPropertyName("authenticationContext")]
    public AuthenticationContext? AuthenticationContext { get; set; }

    [JsonPropertyName("passwordContext")]
    public PasswordContext? PasswordContext { get; set; }

    [JsonPropertyName("encryptedPasswordContext")]
    public string? EncryptedPasswordContext { get; set; }
}

public class AuthenticationContext
{
    [JsonPropertyName("correlationId")]
    public string? CorrelationId { get; set; }

    [JsonPropertyName("client")]
    public ClientInfo? Client { get; set; }

    [JsonPropertyName("protocol")]
    public string? Protocol { get; set; }

    [JsonPropertyName("clientServicePrincipal")]
    public ServicePrincipalInfo? ClientServicePrincipal { get; set; }

    [JsonPropertyName("resourceServicePrincipal")]
    public ServicePrincipalInfo? ResourceServicePrincipal { get; set; }

    [JsonPropertyName("user")]
    public UserInfo? User { get; set; }
}

public class ClientInfo
{
    [JsonPropertyName("ip")]
    public string? Ip { get; set; }

    [JsonPropertyName("locale")]
    public string? Locale { get; set; }

    [JsonPropertyName("market")]
    public string? Market { get; set; }
}

public class ServicePrincipalInfo
{
    [JsonPropertyName("id")]
    public string? Id { get; set; }

    [JsonPropertyName("appId")]
    public string? AppId { get; set; }

    [JsonPropertyName("appDisplayName")]
    public string? AppDisplayName { get; set; }

    [JsonPropertyName("displayName")]
    public string? DisplayName { get; set; }
}

public class UserInfo
{
    [JsonPropertyName("createdDateTime")]
    public string? CreatedDateTime { get; set; }

    [JsonPropertyName("displayName")]
    public string? DisplayName { get; set; }

    [JsonPropertyName("givenName")]
    public string? GivenName { get; set; }

    [JsonPropertyName("id")]
    public string? Id { get; set; }

    [JsonPropertyName("mail")]
    public string? Mail { get; set; }

    [JsonPropertyName("preferredLanguage")]
    public string? PreferredLanguage { get; set; }

    [JsonPropertyName("surname")]
    public string? Surname { get; set; }

    [JsonPropertyName("userPrincipalName")]
    public string? UserPrincipalName { get; set; }

    [JsonPropertyName("userType")]
    public string? UserType { get; set; }
}

public class PasswordContext
{
    [JsonPropertyName("userPassword")]
    public string? UserPassword { get; set; }

    [JsonPropertyName("nonce")]
    public string? Nonce { get; set; }
}

/// <summary>
/// Response to return to External ID Custom Authentication Extension.
/// </summary>
public class CustomAuthenticationExtensionResponse
{
    [JsonPropertyName("data")]
    public ResponseData Data { get; set; }

    public CustomAuthenticationExtensionResponse(ResponseActionType actionType, string? title = null, string? message = null)
    {
        Data = new ResponseData(actionType, title, message);
    }
}

public class ResponseData
{
    [JsonPropertyName("@odata.type")]
    public string ODataType { get; set; } = "microsoft.graph.onPasswordSubmitResponseData";

    [JsonPropertyName("actions")]
    public List<ResponseAction> Actions { get; set; }

    [JsonPropertyName("nonce")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? Nonce { get; set; }

    public ResponseData(ResponseActionType actionType, string? title = null, string? message = null)
    {
        Actions = new List<ResponseAction> { new ResponseAction(actionType, title, message) };
    }
}

public class ResponseAction
{
    [JsonPropertyName("@odata.type")]
    public string ODataType { get; set; }

    [JsonPropertyName("title")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? Title { get; set; }

    [JsonPropertyName("message")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? Message { get; set; }

    public ResponseAction(ResponseActionType actionType, string? title = null, string? message = null)
    {
        ODataType = actionType switch
        {
            ResponseActionType.MigratePassword => "microsoft.graph.passwordsubmit.MigratePassword",
            ResponseActionType.Block => "microsoft.graph.passwordsubmit.Block",
            ResponseActionType.UpdatePassword => "microsoft.graph.passwordsubmit.UpdatePassword",
            ResponseActionType.Retry => "microsoft.graph.passwordsubmit.Retry",
            _ => throw new ArgumentOutOfRangeException(nameof(actionType), actionType, null)
        };

        Title = title;
        Message = message;
    }
}

/// <summary>
/// Available action types for Custom Authentication Extension response.
/// </summary>
public enum ResponseActionType
{
    /// <summary>
    /// Migrate the user's password from the source system.
    /// External ID will set the password to the value provided by the user.
    /// </summary>
    MigratePassword,

    /// <summary>
    /// Block the user from signing in.
    /// Requires title and message to display to the user.
    /// </summary>
    Block,

    /// <summary>
    /// Update the user's password.
    /// </summary>
    UpdatePassword,

    /// <summary>
    /// Ask the user to retry authentication.
    /// </summary>
    Retry
}
