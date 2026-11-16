package handlers

import (
	"path/filepath"
	"testing"

	"github.com/open-uem/openuem-console/internal/wingetrepo"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestDefaultPackageIdentifier(t *testing.T) {
	assert.Equal(t, "ExampleCorp.TestApp", defaultPackageIdentifier("Example Corp.", "Test App"))
	assert.Equal(t, "MullerSohne.TestAppUnicode", defaultPackageIdentifier("Müller & Söhne", "Test App ünicode"))
	assert.Equal(t, "Mozilla.FirefoxESRX64DeDE", defaultPackageIdentifier("Mozilla", "Firefox ESR (x64 de-DE)"))

	p := wingetrepo.Package{PackageIdentifier: defaultPackageIdentifier("7-Zip", "7-Zip 24.08 (x64)"), PackageVersion: "24.08", PackageName: "7-Zip", Publisher: "7-Zip", Architecture: "neutral", InstallerFile: "7z.msi"}
	assert.Equal(t, "7Zip.7Zip2408X64", p.PackageIdentifier)
	assert.NoError(t, p.Validate(), "derived identifiers are valid")
}

func TestInspectInstaller(t *testing.T) {
	testdata := filepath.Join("..", "..", "..", "wingetrepo", "testdata")

	msi, err := inspectInstaller(filepath.Join(testdata, "test.msi"), ".msi")
	require.NoError(t, err)
	assert.Equal(t, wingetrepo.InstallerTypeMSI, msi.InstallerType)
	assert.NotEmpty(t, msi.ProductCode)

	exe, err := inspectInstaller(filepath.Join(testdata, "test-inno.exe"), ".exe")
	require.NoError(t, err)
	assert.Equal(t, installerDetails{InstallerType: wingetrepo.InstallerTypeInno, Name: "Example Tool", Publisher: "Example Corp", Version: "3.1.4"}, exe)

	_, err = inspectInstaller(filepath.Join(testdata, "test.exe"), ".msi")
	assert.Error(t, err, "an exe renamed to .msi")
	_, err = inspectInstaller(filepath.Join(testdata, "test.msi"), ".exe")
	assert.Error(t, err, "an msi renamed to .exe")
	_, err = inspectInstaller(filepath.Join(testdata, "test.msi"), ".zip")
	assert.Error(t, err)
}
