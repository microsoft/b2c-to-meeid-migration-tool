// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
using Azure.Identity;
using Azure.Storage.Blobs;
using Azure.Storage.Blobs.Models;
using B2CMigrationKit.Core.Abstractions;
using B2CMigrationKit.Core.Configuration;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using System.Text;

namespace B2CMigrationKit.Core.Services.Infrastructure;

/// <summary>
/// Provides access to Azure Blob Storage for migration data.
/// </summary>
public class BlobStorageClient : IBlobStorageClient
{
    private readonly BlobServiceClient _serviceClient;
    private readonly ILogger<BlobStorageClient> _logger;
    private readonly StorageOptions _options;

    public BlobStorageClient(
        IOptions<StorageOptions> options,
        ILogger<BlobStorageClient> logger)
    {
        _options = options?.Value ?? throw new ArgumentNullException(nameof(options));
        _logger = logger ?? throw new ArgumentNullException(nameof(logger));

        if (_options.UseManagedIdentity)
        {
            var credential = new DefaultAzureCredential();
            _serviceClient = new BlobServiceClient(new Uri(_options.ConnectionStringOrUri), credential);
            _logger.LogInformation("Blob storage client initialized with Managed Identity");
        }
        else
        {
            _serviceClient = new BlobServiceClient(_options.ConnectionStringOrUri);
            _logger.LogInformation("Blob storage client initialized with connection string");
        }
    }

    public async Task WriteBlobAsync(
        string containerName,
        string blobName,
        string jsonContent,
        CancellationToken cancellationToken = default)
    {
        try
        {
            var containerClient = _serviceClient.GetBlobContainerClient(containerName);
            var blobClient = containerClient.GetBlobClient(blobName);

            var bytes = Encoding.UTF8.GetBytes(jsonContent);
            using var stream = new MemoryStream(bytes);

            await blobClient.UploadAsync(stream, overwrite: true, cancellationToken);

            _logger.LogInformation("Wrote blob: {Container}/{Blob} ({Size} bytes)",
                containerName, blobName, bytes.Length);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to write blob: {Container}/{Blob}", containerName, blobName);
            throw;
        }
    }

    public async Task<string> ReadBlobAsync(
        string containerName,
        string blobName,
        CancellationToken cancellationToken = default)
    {
        try
        {
            var containerClient = _serviceClient.GetBlobContainerClient(containerName);
            var blobClient = containerClient.GetBlobClient(blobName);

            var response = await blobClient.DownloadContentAsync(cancellationToken);
            var content = response.Value.Content.ToString();

            _logger.LogInformation("Read blob: {Container}/{Blob} ({Size} bytes)",
                containerName, blobName, content.Length);

            return content;
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to read blob: {Container}/{Blob}", containerName, blobName);
            throw;
        }
    }

    public async Task<IEnumerable<string>> ListBlobsAsync(
        string containerName,
        string? prefix = null,
        CancellationToken cancellationToken = default)
    {
        try
        {
            var containerClient = _serviceClient.GetBlobContainerClient(containerName);
            var blobs = new List<string>();

            await foreach (var blobItem in containerClient.GetBlobsAsync(prefix: prefix, cancellationToken: cancellationToken))
            {
                blobs.Add(blobItem.Name);
            }

            _logger.LogInformation("Listed {Count} blobs in container: {Container} (prefix: {Prefix})",
                blobs.Count, containerName, prefix ?? "(none)");

            return blobs;
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to list blobs in container: {Container}", containerName);
            throw;
        }
    }

    public async Task<bool> BlobExistsAsync(
        string containerName,
        string blobName,
        CancellationToken cancellationToken = default)
    {
        try
        {
            var containerClient = _serviceClient.GetBlobContainerClient(containerName);
            var blobClient = containerClient.GetBlobClient(blobName);

            var exists = await blobClient.ExistsAsync(cancellationToken);

            return exists.Value;
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to check blob existence: {Container}/{Blob}", containerName, blobName);
            throw;
        }
    }

    public async Task EnsureContainerExistsAsync(
        string containerName,
        CancellationToken cancellationToken = default)
    {
        try
        {
            var containerClient = _serviceClient.GetBlobContainerClient(containerName);
            await containerClient.CreateIfNotExistsAsync(PublicAccessType.None, cancellationToken: cancellationToken);

            _logger.LogInformation("Ensured container exists: {Container}", containerName);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to ensure container exists: {Container}", containerName);
            throw;
        }
    }
}
