// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
namespace B2CMigrationKit.Core.Models;

/// <summary>
/// Represents the result of password complexity validation.
/// </summary>
public class PasswordValidationResult
{
    /// <summary>
    /// Gets or sets whether the password is valid.
    /// </summary>
    public bool IsValid { get; set; }

    /// <summary>
    /// Gets or sets validation error messages.
    /// </summary>
    public List<string> Errors { get; set; } = new();

    /// <summary>
    /// Gets or sets whether the password meets minimum length requirements.
    /// </summary>
    public bool MeetsLengthRequirement { get; set; }

    /// <summary>
    /// Gets or sets whether the password contains uppercase characters.
    /// </summary>
    public bool HasUppercase { get; set; }

    /// <summary>
    /// Gets or sets whether the password contains lowercase characters.
    /// </summary>
    public bool HasLowercase { get; set; }

    /// <summary>
    /// Gets or sets whether the password contains digits.
    /// </summary>
    public bool HasDigit { get; set; }

    /// <summary>
    /// Gets or sets whether the password contains special characters.
    /// </summary>
    public bool HasSpecialCharacter { get; set; }

    /// <summary>
    /// Creates a successful validation result.
    /// </summary>
    public static PasswordValidationResult CreateValid()
    {
        return new PasswordValidationResult
        {
            IsValid = true,
            MeetsLengthRequirement = true,
            HasUppercase = true,
            HasLowercase = true,
            HasDigit = true,
            HasSpecialCharacter = true
        };
    }

    /// <summary>
    /// Creates a failed validation result.
    /// </summary>
    public static PasswordValidationResult CreateInvalid(params string[] errors)
    {
        return new PasswordValidationResult
        {
            IsValid = false,
            Errors = errors.ToList()
        };
    }
}
