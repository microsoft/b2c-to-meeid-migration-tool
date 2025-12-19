// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
namespace B2CMigrationKit.Core.Abstractions;

/// <summary>
/// Provides access to Azure Blob Storage operations for migration data.
/// </summary>
public interface IBlobStorageClient
{
    /// <summary>
    /// Writes JSON content to a blob.
    /// </summary>
    /// <param name="containerName">The container name.</param>
    /// <param name="blobName">The blob name.</param>
    /// <param name="jsonContent">The JSON content to write.</param>
    /// <param name="cancellationToken">Token to cancel the operation.</param>
    Task WriteBlobAsync(
        string containerName,
        string blobName,
        string jsonContent,
        CancellationToken cancellationToken = default);

    /// <summary>
    /// Reads JSON content from a blob.
    /// </summary>
    /// <param name="containerName">The container name.</param>
    /// <param name="blobName">The blob name.</param>
    /// <param name="cancellationToken">Token to cancel the operation.</param>
    /// <returns>The JSON content of the blob.</returns>
    Task<string> ReadBlobAsync(
        string containerName,
        string blobName,
        CancellationToken cancellationToken = default);

    /// <summary>
    /// Lists all blobs in a container with an optional prefix.
    /// </summary>
    /// <param name="containerName">The container name.</param>
    /// <param name="prefix">Optional prefix to filter blobs.</param>
    /// <param name="cancellationToken">Token to cancel the operation.</param>
    /// <returns>Collection of blob names.</returns>
    Task<IEnumerable<string>> ListBlobsAsync(
        string containerName,
        string? prefix = null,
        CancellationToken cancellationToken = default);

    /// <summary>
    /// Checks if a blob exists.
    /// </summary>
    /// <param name="containerName">The container name.</param>
    /// <param name="blobName">The blob name.</param>
    /// <param name="cancellationToken">Token to cancel the operation.</param>
    /// <returns>True if the blob exists, false otherwise.</returns>
    Task<bool> BlobExistsAsync(
        string containerName,
        string blobName,
        CancellationToken cancellationToken = default);

    /// <summary>
    /// Ensures a container exists, creating it if necessary.
    /// </summary>
    /// <param name="containerName">The container name.</param>
    /// <param name="cancellationToken">Token to cancel the operation.</param>
    Task EnsureContainerExistsAsync(
        string containerName,
        CancellationToken cancellationToken = default);
}
