# Contributing to B2C Migration Kit

Thank you for your interest in contributing to the B2C Migration Kit! This project is a sample implementation for migrating users from Azure AD B2C to Microsoft Entra External ID.

## 🎯 Project Status

This project is currently a **preview/sample implementation** showcasing Just-In-Time password migration. While we welcome contributions, please note this is not yet production-ready.

## 📋 Ways to Contribute

- **Bug Reports**: Submit detailed issue reports with reproduction steps
- **Feature Suggestions**: Propose enhancements or new capabilities
- **Documentation**: Improve guides, examples, or troubleshooting
- **Code**: Submit pull requests with bug fixes or features

## 🚀 Getting Started

### Prerequisites

- .NET 8.0 SDK or later
- PowerShell 7.0+ (for automation scripts)
- Azure subscription with B2C and External ID tenants
- Visual Studio 2022 or VS Code

### Local Development Setup

1. **Clone the repository**
   ```bash
   git clone https://github.com/alvesfabi/B2C-Migration-Kit.git
   cd B2C-Migration-Kit
   ```

2. **Install dependencies**
   ```bash
   dotnet restore
   ```

3. **Configure local settings**
   ```bash
   cd src/B2CMigrationKit.Console
   cp appsettings.json appsettings.local.json
   # Edit appsettings.local.json with your tenant credentials
   ```

4. **Set up Azurite (local storage emulator)**
   ```bash
   npm install -g azurite
   azurite --silent --location .azurite --debug .azurite\debug.log
   ```

5. **Build the solution**
   ```bash
   dotnet build
   ```

For detailed setup instructions, see the [Developer Guide](docs/DEVELOPER_GUIDE.md).

## 🔨 Making Changes

### Branching Strategy

- `main` - Stable branch for releases
- `feature/*` - New features or enhancements
- `bugfix/*` - Bug fixes
- `docs/*` - Documentation updates

### Coding Standards

- **C#**: Follow [Microsoft C# Coding Conventions](https://learn.microsoft.com/dotnet/csharp/fundamentals/coding-style/coding-conventions)
- **Naming**: Use PascalCase for classes/methods, camelCase for variables
- **Comments**: Add XML documentation for public APIs
- **Error Handling**: Use structured exceptions with appropriate logging
- **Async/Await**: Use async patterns for I/O operations

### Testing

- Write unit tests for new features using xUnit
- Ensure existing tests pass: `dotnet test`
- Test locally with Azurite before submitting PR

### Commit Messages

Use clear, descriptive commit messages:

```
Add support for custom attribute mapping

- Implement flexible attribute transformation
- Add configuration validation
- Update documentation with examples
```

## 📝 Pull Request Process

1. **Create an issue** describing the change (for non-trivial changes)
2. **Fork the repository** and create a feature branch
3. **Make your changes** following coding standards
4. **Add tests** for new functionality
5. **Update documentation** if needed
6. **Submit a pull request** with:
   - Clear description of changes
   - Link to related issue
   - Screenshots (for UI changes)
   - Test results

### PR Checklist

- [ ] Code follows project coding standards
- [ ] Tests added/updated and passing
- [ ] Documentation updated (README, guides, comments)
- [ ] No secrets or credentials in code
- [ ] Commit messages are clear and descriptive
- [ ] PR description explains what/why

## 🔐 Security

- **Never commit secrets**: Use configuration files (gitignored)
- **Report vulnerabilities**: See [SECURITY.md](SECURITY.md) for responsible disclosure
- **Review dependencies**: Ensure third-party packages are secure

## 📜 Code of Conduct

This project has adopted the [Microsoft Open Source Code of Conduct](https://opensource.microsoft.com/codeofconduct/).

For more information see the [Code of Conduct FAQ](https://opensource.microsoft.com/codeofconduct/faq/) or contact [opencode@microsoft.com](mailto:opencode@microsoft.com) with additional questions or comments.

## 📄 Contributor License Agreement

This project welcomes contributions and suggestions. Most contributions require you to agree to a Contributor License Agreement (CLA) declaring that you have the right to, and actually do, grant us the rights to use your contribution.

When you submit a pull request, a CLA-bot will automatically determine whether you need to provide a CLA and decorate the PR appropriately (e.g., label, comment). Simply follow the instructions provided by the bot. You will only need to do this once across all repositories using our CLA.

## 🎓 Resources

- [Developer Guide](docs/DEVELOPER_GUIDE.md) - Technical implementation details
- [Architecture Guide](docs/ARCHITECTURE_GUIDE.md) - System design and architecture
- [Scripts README](scripts/README.md) - Automation scripts documentation
- [Microsoft Entra Documentation](https://learn.microsoft.com/entra/)

## 💬 Questions?

- **GitHub Issues**: For bugs and feature requests
- **GitHub Discussions**: For questions and general discussion

Thank you for contributing! 🎉
