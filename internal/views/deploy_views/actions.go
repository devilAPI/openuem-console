package deploy_views

// Actions that can be requested from the Deploy section
const (
	ActionInstall   = "install"
	ActionUpdate    = "update"
	ActionUninstall = "uninstall"
	// ActionUpdateAll updates every package that has an available update
	ActionUpdateAll = "updateall"
)

// ParseAction validates the deploy action sent in a form. The "true" and "false" values
// of the former installation type boolean are still accepted, as they may be bookmarked.
func ParseAction(value string) (string, bool) {
	switch value {
	case "true":
		return ActionInstall, true
	case "false":
		return ActionUninstall, true
	case ActionInstall, ActionUpdate, ActionUninstall, ActionUpdateAll:
		return value, true
	}
	return "", false
}

// actionPath returns the path of the Deploy section page for an action
func actionPath(action string) string {
	return "/deploy/" + action
}

// searchPath returns the path used to search packages for an action
func searchPath(action string) string {
	return "/deploy/search" + action
}

// actionTitle returns the translation key of the title of an action
func actionTitle(action string) string {
	switch action {
	case ActionUpdate:
		return "Update"
	case ActionUninstall:
		return "Uninstall"
	case ActionUpdateAll:
		return "updateall.tab"
	default:
		return "Install"
	}
}

// actionIcon returns the icon used for an action
func actionIcon(action string) string {
	switch action {
	case ActionUpdate, ActionUpdateAll:
		return "package-check"
	case ActionUninstall:
		return "package-minus"
	default:
		return "package-plus"
	}
}

// UpdateRequestFailure describes a computer that couldn't start updating its packages
type UpdateRequestFailure struct {
	Computer string
	Reason   string
}
