// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
namespace B2CMigrationKit.Core.Configuration;

/// <summary>
/// Configuration options for the asynchronous phone-authentication-method registration worker.
/// This is a separate, throttle-controlled operation that runs after import to register
/// MFA phone numbers in Entra External ID without impacting the main import throughput.
/// </summary>
public class PhoneRegistrationOptions
{
    /// <summary>
    /// Name of the Azure Queue used to buffer phone-registration tasks.
    /// Default: "phone-registration"
    /// </summary>
    public string QueueName { get; set; } = "phone-registration";

    /// <summary>
    /// Minimum delay (ms) between processing consecutive queue messages.
    /// Each message makes one API call to B2C (GET phoneMethods) and one to EEID (POST phoneMethods).
    /// The phoneMethods API has a different throttle budget than the main Users API.
    /// Increase this value if you observe sustained HTTP 429 responses.
    /// To increase throughput, run additional workers each with dedicated B2C and EEID app registrations.
    /// Default: 400 ms
    /// </summary>
    public int ThrottleDelayMs { get; set; } = 400;

    /// <summary>
    /// How long (seconds) a dequeued message is invisible to other workers while being processed.
    /// If processing fails, the message becomes visible again after this timeout for a retry.
    /// Default: 120 seconds
    /// </summary>
    public int MessageVisibilityTimeoutSeconds { get; set; } = 120;

    /// <summary>
    /// How long the worker polls when the queue is empty before checking again.
    /// Default: 5000 ms
    /// </summary>
    public int EmptyQueuePollDelayMs { get; set; } = 5000;

    /// <summary>
    /// Maximum number of consecutive empty-queue polls before the worker exits.
    /// Set to 0 to run indefinitely (useful when running as a background service).
    /// Default: 3
    /// </summary>
    public int MaxEmptyPolls { get; set; } = 3;

    /// <summary>
    /// Maximum number of phone-registration messages processed concurrently (default: 1 = serial).
    /// Each concurrent slot makes one GET (B2C) + one POST (EEID); the ThrottleDelayMs delay
    /// applies after every individual slot completes. Increase only if the phoneMethods
    /// budget allows it — lower throttle budget than the main Users API.
    /// </summary>
    [System.ComponentModel.DataAnnotations.Range(1, 10)]
    public int MaxConcurrency { get; set; } = 1;

    /// <summary>
    /// When <c>true</c>, users with no MFA phone in B2C are assigned a synthetic E.164
    /// phone number derived deterministically from their B2CUserId instead of being skipped.
    /// This allows benchmarking the EEID phoneMethods POST API when real B2C phone data
    /// is not available. <b>Never enable in production.</b>
    /// Default: false
    /// </summary>
    public bool UseFakePhoneWhenMissing { get; set; } = false;
}
