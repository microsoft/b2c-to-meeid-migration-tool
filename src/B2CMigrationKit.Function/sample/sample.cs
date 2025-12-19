// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
using System;
using System.IO;
using System.Threading.Tasks;
using System.Collections.Generic;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Http;
using Microsoft.Azure.WebJobs;
using Microsoft.Azure.WebJobs.Extensions.Http;
using Microsoft.Extensions.Logging;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;
using System.Security.Cryptography;
using Jose;

namespace cust_auth_functions
{
    /// <summary>
    /// Azure Function for Just-In-Time (JIT) user migration in Entra External ID.
    /// This function handles authentication events and migrates users from legacy systems.
    /// </summary>
    public static class JitMigrationTemplate
    {
        #region Configuration Constants 

        /// <summary>
        /// Private key for decrypting the encrypted password context
        /// This should be the private part of the key configured in your External ID tenant
        /// </summary>
        private const string DECRYPTION_PRIVATE_KEY = @"-----BEGIN PRIVATE KEY-----

-----END PRIVATE KEY-----";

        #endregion

        /// <summary>
        /// Main Azure Function entry point for handling JIT migration requests
        /// </summary>
        /// <param name="req">The HTTP request from Entra External ID</param>
        /// <param name="log">Logger instance for tracking execution</param>
        /// <returns>Action result containing the migration response</returns>
        [FunctionName("JitMigrationTemplate")]
        public static async Task<IActionResult> Run( 
        [HttpTrigger(AuthorizationLevel.Anonymous, "get", "post", Route = null)] 
        HttpRequest req, 
        ILogger log) 
    { 
        log.LogInformation($"Processing {req.Method} request for JIT migration."); 
 
        // Handle GET requests (health check) 
        if (req.Method == HttpMethods.Get) 
        { 
            log.LogInformation("GET request received. Returning 200 OK for health check."); 
            return new OkResult(); 
        } 
 
        // Validate request body 
        if (req.Body == null || req.Body.Length == 0) 
        { 
            log.LogError("Request body is empty or null."); 
            return new BadRequestObjectResult("Request body is required for POST requests."); 
        } 
 
        try 
        { 
            // Parse the incoming request to extract user information 
            var (userId, userPassword, nonce) = await ParseRequestAsync(req, log); 
             
            if (string.IsNullOrEmpty(userId)) 
            { 
                log.LogError("User ID is missing from the request."); 
                return new BadRequestObjectResult("User ID is required in the authentication context."); 
            } 
 
            if (string.IsNullOrEmpty(userPassword)) 
            { 
                log.LogError("User password is missing from the request."); 
                return new BadRequestObjectResult("User password is required for migration."); 
            } 
 
            // Process the response based on legacy system validation 
            ResponseContent response = await ProcessResponse(req, userId, userPassword, nonce, log); 
             
            log.LogInformation($"Returning response action: {response.Data.Actions[0].OdataType}."); 
 
            return new OkObjectResult(response); 
        } 
        catch (Exception ex) 
        { 
            log.LogError($"Unexpected error during JIT migration processing: {ex.Message}"); 
            log.LogError($"Stack trace: {ex.StackTrace}"); 
             
            // Return a generic error response to avoid exposing internal details 
            return new StatusCodeResult(StatusCodes.Status500InternalServerError); 
        } 
    } 
 
    #region Core Processing Methods 
 
    /// <summary> 
    /// Processes the migration response by validating credentials against a legacy authentication system. 
    /// This example demonstrates how to integrate with your existing user store to determine migration actions. 
    /// </summary> 
    /// <param name="req">The HTTP request containing query parameters</param> 
    /// <param name="userId">The user ID to validate</param> 
    /// <param name="password">The user's password to validate</param> 
    /// <param name="nonce">The nonce from the request</param> 
    /// <param name="log">Logger instance</param> 
    /// <returns>ResponseContent with appropriate action based on legacy system validation</returns> 
    private static async Task<ResponseContent> ProcessResponse(HttpRequest req, string userId, string password, string nonce, ILogger log) 
    { 
        log.LogInformation($"Processing JIT migration response for user: {userId}"); 
 
        // TODO: Call your legacy authentication provider here 
        // 
        // Then based on the response from your legacy provider: 
        // - If authentication successful AND password strong: return MigratePassword 
        // - If authentication successful BUT password weak: return UpdatePassword   
        // - If authentication failed: return Retry 
        // - If system error: return Block 
 
        // PLACEHOLDER: Always return Retry for now 
        log.LogInformation("Using placeholder implementation - returning Retry action"); 
         
        return CreateResponse(ResponseActionType.Retry, nonce, "Authentication Pending",  
            "Please implement legacy authentication integration."); 
    } 
 
    /// <summary> 
    /// Creates a response with the specified action type and user-facing messages 
    /// </summary> 
    /// <param name="actionType">The response action type</param> 
    /// <param name="nonce">The nonce from the request</param> 
    /// <param name="title">User-facing title (optional)</param> 
    /// <param name="message">User-facing message (optional)</param> 
    /// <returns>ResponseContent with the specified action and messages</returns> 
    private static ResponseContent CreateResponse(ResponseActionType actionType, string nonce, string title = null, string message = null) 
    { 
        var response = new ResponseContent(actionType, nonce); 
         
        if (!string.IsNullOrEmpty(title)) 
            response.Data.Actions[0].Title = title; 
             
        if (!string.IsNullOrEmpty(message)) 
            response.Data.Actions[0].Message = message; 
             
        return response; 
    } 
 
 
    /// <summary> 
    /// Parses the incoming request to extract user ID, password, and nonce 
    /// </summary> 
    private static async Task<(string userId, string userPassword, string nonce)> ParseRequestAsync(HttpRequest req, ILogger log) 
    { 
        log.LogInformation($"Parsing request from URL: {req.Path}{req.QueryString}"); 
 
        string requestBody = await new StreamReader(req.Body).ReadToEndAsync(); 
        if (string.IsNullOrWhiteSpace(requestBody)) 
        { 
            log.LogError("Request body is empty or whitespace."); 
            return (null, null, null); 
        } 
 
        try 
        { 
            JObject jObject = JObject.Parse(requestBody); 
            log.LogDebug($"Parsed request body: {jObject}"); 
 
            // Extract user ID from authentication context 
            string userId = jObject["data"]?["authenticationContext"]?["user"]?["id"]?.ToString(); 
             
            // Handle both encrypted and plain text password contexts 
            string encryptedPasswordContext = jObject["data"]?["encryptedPasswordContext"]?.ToString(); 
 
            (string userPassword, string nonce) = ExtractPasswordAndNonce(encryptedPasswordContext, log); 
 
            return (userId, userPassword, nonce); 
        } 
        catch (JsonReaderException ex) 
        { 
            log.LogError($"Failed to parse request body as JSON: {ex.Message}"); 
            return (null, null, null); 
        } 
    } 
 
    /// <summary> 
    /// Extracts password and nonce from encrypted password context using RSA decryption 
    /// </summary> 
    private static (string password, string nonce) ExtractPasswordAndNonce(string encryptedContext, ILogger log) 
    { 
        try 
        { 
            log.LogInformation("Starting password and nonce extraction from encrypted context"); 
 
            // Validate input 
            if (string.IsNullOrEmpty(encryptedContext)) 
            { 
                log.LogError("Encrypted context is null or empty"); 
                return (string.Empty, string.Empty); 
            } 
 
            RSA rsa = null; 
            try 
            { 
                // Create and configure RSA instance 
                rsa = RSA.Create(); 
                log.LogDebug("RSA instance created successfully"); 
 
                // Import the private key 
                rsa.ImportFromPem(DECRYPTION_PRIVATE_KEY); 
                log.LogDebug("Private key imported successfully"); 
            } 
            catch (CryptographicException ex) 
            { 
                log.LogError($"Failed to initialize RSA or import private key: {ex.Message}"); 
                return (string.Empty, string.Empty); 
            } 
 
            string decryptedPayload;
            try
            {
                // Decrypt the JWT
                log.LogDebug("Attempting JWT decryption");
                decryptedPayload = JWT.Decode(encryptedContext, rsa);
                log.LogDebug($"JWT decrypted successfully, payload length: {decryptedPayload?.Length ?? 0}");

                if (string.IsNullOrEmpty(decryptedPayload))
                {
                    log.LogError("JWT decryption resulted in empty payload");
                    return (string.Empty, string.Empty);
                }
            }
            catch (Jose.JoseException ex)
            {
                log.LogError($"Jose JWT library error during decryption: {ex.Message}");
                return (string.Empty, string.Empty);
            }
            finally
            {
                // Dispose of RSA instance
                rsa?.Dispose();
                log.LogDebug("RSA instance disposed");
            }

            JObject payloadObj;
            try
            {
                // Parse the decrypted JSON payload (already decoded by JWT.Decode above)
                log.LogDebug("Parsing decrypted JSON payload");
                payloadObj = JObject.Parse(decryptedPayload);
                log.LogDebug("JSON payload parsed successfully");                // Log the parsed JSON token structure (for debugging - remove in production) 
                log.LogDebug($"Decrypted payload structure: {payloadObj.ToString(Formatting.Indented)}"); 
            } 
            catch (JsonReaderException ex) 
            { 
                log.LogError($"Failed to parse decrypted payload as JSON: {ex.Message}"); 
                return (string.Empty, string.Empty); 
            } 
 
            // Extract password and nonce from the payload 
            string password = payloadObj["user-password"]?.ToString(); 
            string nonce = payloadObj["nonce"]?.ToString(); 
 
            log.LogInformation($"Password extraction: {(string.IsNullOrEmpty(password) ? "FAILED" : "SUCCESS")}"); 
            log.LogInformation($"Nonce extraction: {(string.IsNullOrEmpty(nonce) ? "FAILED" : "SUCCESS")}"); 
 
            return (password ?? string.Empty, nonce ?? string.Empty); 
        } 
        catch (Exception ex) 
        { 
            log.LogError($"Critical error in ExtractPasswordAndNonce: {ex.Message}"); 
            log.LogError($"Stack trace: {ex.StackTrace}"); 
             
            // Return empty values to allow the function to continue with fallback behavior 
            return (string.Empty, string.Empty); 
        } 
    } 
 
    #endregion 
 
    #region Response Models 
 
    /// <summary> 
    /// Root response object for JIT migration 
    /// </summary> 
    public class ResponseContent 
    { 
        [JsonProperty("data")] 
        public Data Data { get; set; } 
 
        public ResponseContent(ResponseActionType actionType, string nonce = null) 
        { 
            Data = new Data(actionType, nonce); 
        } 
    } 
 
    /// <summary> 
    /// Data payload containing actions and metadata 
    /// </summary> 
    public class Data 
    { 
        [JsonProperty("@odata.type")] 
        public string OdataType { get; set; } 
 
        [JsonProperty("actions")] 
        public List<ActionItem> Actions { get; set; } 
 
        [JsonProperty("nonce")] 
        public string Nonce { get; set; } 
 
        public Data(ResponseActionType actionType, string nonce = null) 
        { 
            OdataType = "microsoft.graph.onPasswordSubmitResponseData"; 
            Nonce = nonce; 
            Actions = new List<ActionItem> { new ActionItem(actionType) }; 
        } 
    } 
 
    /// <summary> 
    /// Individual action item in the response 
    /// </summary> 
    public class ActionItem 
    { 
        [JsonProperty("@odata.type")] 
        public string OdataType { get; set; } 
 
        [JsonProperty("title", DefaultValueHandling = DefaultValueHandling.Ignore)] 
        public string Title { get; set; } 
 
        [JsonProperty("message", DefaultValueHandling = DefaultValueHandling.Ignore)] 
        public string Message { get; set; } 
 
        public ActionItem(ResponseActionType type)
        {
            OdataType = type switch
            {
                ResponseActionType.MigratePassword => "microsoft.graph.authenticationEvent.passwordSubmit.migratePassword",
                ResponseActionType.UpdatePassword => "microsoft.graph.authenticationEvent.passwordSubmit.updatePassword",
                ResponseActionType.Block => "microsoft.graph.authenticationEvent.passwordSubmit.block",
                ResponseActionType.Retry => "microsoft.graph.authenticationEvent.passwordSubmit.retry",
                _ => throw new ArgumentOutOfRangeException(nameof(type), type, null)
            }; 
 
            // Set user-facing messages for block actions 
            if (type == ResponseActionType.Block) 
            { 
                Title = "Sign-in blocked"; 
                Message = "Admin has blocked your sign-in attempt. Please contact support."; 
            } 
        } 
    } 
 
    /// <summary> 
    /// Available response action types for JIT migration 
    /// </summary> 
    public enum ResponseActionType 
    { 
        /// <summary> 
        /// Migrate the user's password to Azure AD 
        /// </summary> 
        MigratePassword, 
         
        /// <summary> 
        /// Update the user's existing password 
        /// </summary> 
        UpdatePassword, 
         
        /// <summary> 
        /// Block the user's sign-in attempt 
        /// </summary> 
        Block, 
         
        /// <summary> 
        /// Retry the authentication process 
        /// </summary> 
        Retry 
    } 
 
        #endregion
    }
} 