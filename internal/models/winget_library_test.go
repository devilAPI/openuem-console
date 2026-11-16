package models

import (
	"context"
	"testing"

	"github.com/open-uem/ent/enttest"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestLibraryPackagesInCatalog(t *testing.T) {
	ctx := context.Background()
	client := enttest.Open(t, "sqlite3", "file:wingetlibrary?mode=memory&_fk=1")
	defer client.Close()
	m := Model{Client: client}

	client.SoftwarePackage.Create().SetPackageID("Example.Community").SetName("Example Tool").SetSource("winget").ExecX(ctx)
	client.SoftwarePackage.Create().SetPackageID("Example.Flatpak").SetName("Example Tool").SetSource("flatpak").ExecX(ctx)
	require.NoError(t, m.SetLibraryPackageInCatalog("ExampleCorp.Tool", "Example Tool"))

	isLibrary, err := m.IsLibraryPackage("ExampleCorp.Tool")
	require.NoError(t, err)
	assert.True(t, isLibrary)
	isLibrary, err = m.IsLibraryPackage("Example.Community")
	require.NoError(t, err)
	assert.False(t, isLibrary, "a package of winget's community repository")

	// The task form's search finds both winget sources, not other package managers
	found, err := m.SearchAllWingetPackages("example tool")
	require.NoError(t, err)
	ids := []string{}
	for _, p := range found {
		ids = append(ids, p.PackageID)
	}
	assert.ElementsMatch(t, []string{"Example.Community", "ExampleCorp.Tool"}, ids)

	require.NoError(t, m.RemoveLibraryPackageFromCatalog("ExampleCorp.Tool"))
	isLibrary, err = m.IsLibraryPackage("ExampleCorp.Tool")
	require.NoError(t, err)
	assert.False(t, isLibrary, "removed from the library")
}
