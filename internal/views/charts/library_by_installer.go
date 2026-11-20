package charts

import (
	"context"
	"sort"
	"strconv"

	"github.com/go-echarts/go-echarts/v2/charts"
	"github.com/go-echarts/go-echarts/v2/opts"
	"github.com/go-echarts/go-echarts/v2/render"
	"github.com/invopop/ctxi18n/i18n"
	"github.com/open-uem/openuem-console/internal/wingetrepo"
)

// installerTypeKeys maps the installer types of the software library to the locale
// keys of their names, see wingetrepo.Package.Type
var installerTypeKeys = map[string]string{
	wingetrepo.InstallerTypeMSI:      "library.type_msi",
	wingetrepo.InstallerTypeEXE:      "library.type_exe",
	wingetrepo.InstallerTypeInno:     "library.type_inno",
	wingetrepo.InstallerTypeNullsoft: "library.type_nullsoft",
	wingetrepo.InstallerTypeBurn:     "library.type_burn",
	wingetrepo.InstallerTypeMSIX:     "library.type_msix",
}

// LibraryPackagesByInstaller shows the packages of the private winget repository by
// the type of their installer, with the total number of packages in the center of
// the pie. Packages stored before other types were supported don't have a type and
// are MSI packages
func LibraryPackagesByInstaller(ctx context.Context, countByType map[string]int, countAllPackages int) render.ChartSnippet {
	pie := charts.NewPie()

	installerTypes := make([]string, 0, len(countByType))
	for installerType := range countByType {
		installerTypes = append(installerTypes, installerType)
	}
	sort.Strings(installerTypes)

	pieData := []opts.PieData{}
	for _, installerType := range installerTypes {
		name := installerType
		if key, known := installerTypeKeys[installerType]; known {
			name = i18n.T(ctx, key)
		}
		pieData = append(pieData, opts.PieData{
			Name:  name,
			Value: countByType[installerType],
		})
	}

	pie.AddSeries(i18n.T(ctx, "charts.library_by_installer"), pieData).SetSeriesOptions(
		charts.WithLabelOpts(opts.Label{Show: opts.Bool(false), Formatter: "{b}: {c}"}),
		charts.WithPieChartOpts(opts.PieChart{
			Radius: []string{"40%", "75%"},
			Center: []string{"25%", "50%"},
		}),
	)

	leftTitle := getLeftTitlePercentage(countAllPackages)

	textStyle := opts.TextStyle{FontSize: 36, Color: "#777"}
	labelStyle := opts.TextStyle{Color: "#777"}

	pie.SetGlobalOptions(
		charts.WithTitleOpts(opts.Title{Title: strconv.Itoa(countAllPackages), Left: leftTitle, Top: "43%", TitleStyle: &textStyle}),
		charts.WithLegendOpts(opts.Legend{Show: opts.Bool(true), TextStyle: &labelStyle, Type: "scroll", Orient: "vertical", X: "left", Y: "center", Left: "55%"}),
		charts.WithColorsOpts(opts.Colors{"#9e0142", "#f46d43", "#fdae61", "#fee08b", "#e6f598", "#abdda4"}),
		charts.WithInitializationOpts(opts.Initialization{
			Width:  "480px",
			Height: "300px",
		}),
	)

	return pie.RenderSnippet()
}
