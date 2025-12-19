// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
namespace B2CMigrationKit.Core.Models;

/// <summary>
/// Represents a paged result from Microsoft Graph API.
/// </summary>
/// <typeparam name="T">The type of items in the result.</typeparam>
public class PagedResult<T>
{
    /// <summary>
    /// Gets or sets the items in the current page.
    /// </summary>
    public List<T> Items { get; set; } = new();

    /// <summary>
    /// Gets or sets the skip token for retrieving the next page.
    /// </summary>
    public string? NextPageToken { get; set; }

    /// <summary>
    /// Gets whether there are more pages available.
    /// </summary>
    public bool HasMorePages => !string.IsNullOrEmpty(NextPageToken);

    /// <summary>
    /// Gets the count of items in the current page.
    /// </summary>
    public int Count => Items.Count;
}
