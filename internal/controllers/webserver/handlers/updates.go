package handlers

import (
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"sync"
	"time"

	"github.com/invopop/ctxi18n/i18n"
	"github.com/labstack/echo/v4"
	"github.com/nats-io/nats.go"
	openuem_nats "github.com/open-uem/nats"
	"github.com/open-uem/openuem-console/internal/views/computers_views"
	"github.com/open-uem/openuem-console/internal/views/deploy_views"
	"github.com/open-uem/openuem-console/internal/views/partials"
)

const (
	// Listing updates can take a while: winget runs as SYSTEM and in every user session
	listPackageUpdatesTimeout = 10 * time.Minute
	// Agents answer as soon as an update run starts
	updatePackagesTimeout = 10 * time.Second
	// Maximum number of agents asked to update packages at the same time
	updatePackagesConcurrency = 16
)

// DeployUpdate shows the page to update a package on several agents
func (h *Handler) DeployUpdate(c echo.Context) error {
	return h.DeployAction(c, deploy_views.ActionUpdate)
}

// DeployUpdateAll shows the agents where every package with an available update can be updated
func (h *Handler) DeployUpdateAll(c echo.Context) error {
	return h.SelectAgentsForDeployment(c, deploy_views.ActionUpdateAll)
}

// UpdateAllPackagesOnAgents asks the agents to update every package with an available update
func (h *Handler) UpdateAllPackagesOnAgents(c echo.Context, agentIDs []string, commonInfo *partials.CommonInfo) error {
	if h.NATSConnection == nil || !h.NATSConnection.IsConnected() {
		return RenderError(c, partials.ErrorMessage(i18n.T(c.Request().Context(), "nats.not_connected"), false))
	}

	// Only agents of the current organization and site can be asked
	nicknames := map[string]string{}
	allowed := []string{}
	for _, agentID := range agentIDs {
		agent, err := h.Model.GetAgentById(agentID, commonInfo)
		if err != nil {
			continue
		}
		nicknames[agentID] = agent.Nickname
		allowed = append(allowed, agentID)
	}
	if len(allowed) == 0 {
		return RenderError(c, partials.ErrorMessage(i18n.T(c.Request().Context(), "agents.no_selected_agents_to_deploy"), true))
	}

	failures := []deploy_views.UpdateRequestFailure{}
	for agentID, err := range h.requestPackageUpdates(allowed, nil) {
		failures = append(failures, deploy_views.UpdateRequestFailure{Computer: nicknames[agentID], Reason: updateRequestErrorMessage(c, err)})
	}

	return RenderView(c, deploy_views.DeployIndex("| Deploy", deploy_views.UpdateAllRequested(c, len(allowed)-len(failures), failures, commonInfo), commonInfo))
}

// requestPackageUpdates asks several agents, concurrently, to start an update run. It returns
// the agents that couldn't start it, e.g. because they're offline or already updating.
func (h *Handler) requestPackageUpdates(agentIDs []string, packages []openuem_nats.AvailableUpdate) map[string]error {
	var mu sync.Mutex
	var wg sync.WaitGroup
	failures := map[string]error{}
	limit := make(chan struct{}, updatePackagesConcurrency)

	for _, agentID := range agentIDs {
		wg.Add(1)
		go func() {
			defer wg.Done()
			limit <- struct{}{}
			defer func() { <-limit }()

			if err := h.requestAgentPackageUpdates(agentID, packages); err != nil {
				mu.Lock()
				failures[agentID] = err
				mu.Unlock()
			}
		}()
	}
	wg.Wait()

	return failures
}

// errAgentUpdateRefused is returned when the agent refuses to start an update run
type errAgentUpdateRefused struct{ reason string }

func (e errAgentUpdateRefused) Error() string { return e.reason }

func (h *Handler) requestAgentPackageUpdates(agentID string, packages []openuem_nats.AvailableUpdate) error {
	data, err := json.Marshal(openuem_nats.UpdatePackagesRequest{AgentId: agentID, Packages: packages})
	if err != nil {
		return err
	}

	msg, err := h.NATSConnection.Request("agent.updatepackages."+agentID, data, updatePackagesTimeout)
	if err != nil {
		return err
	}

	if len(msg.Data) > 0 {
		return errAgentUpdateRefused{reason: string(msg.Data)}
	}
	return nil
}

func updateRequestErrorMessage(c echo.Context, err error) string {
	var refused errAgentUpdateRefused
	switch {
	case errors.Is(err, nats.ErrNoResponders):
		return i18n.T(c.Request().Context(), "package_updates.agent_not_reachable")
	case errors.Is(err, nats.ErrTimeout):
		return i18n.T(c.Request().Context(), "package_updates.agent_timeout")
	case errors.As(err, &refused):
		return refused.reason
	default:
		return err.Error()
	}
}

// ComputerUpdates shows the page where the available updates of a computer are listed
func (h *Handler) ComputerUpdates(c echo.Context) error {
	commonInfo, err := h.GetCommonInfo(c)
	if err != nil {
		return err
	}

	agentID := c.Param("uuid")
	if agentID == "" {
		return RenderError(c, partials.ErrorMessage(i18n.T(c.Request().Context(), "agents.no_empty_id"), false))
	}

	agent, err := h.Model.GetAgentById(agentID, commonInfo)
	if err != nil {
		return RenderView(c, computers_views.InventoryIndex(" | Inventory", partials.Error(c, err.Error(), "Computers", partials.GetNavigationUrl(commonInfo, "/computers"), commonInfo), commonInfo))
	}

	tenantID, err := strconv.Atoi(commonInfo.TenantID)
	if err != nil {
		return RenderError(c, partials.ErrorMessage(i18n.T(c.Request().Context(), "tenants.could_not_convert_to_int", err.Error()), true))
	}
	settings, err := h.Model.GetNetbirdSettings(tenantID)
	if err != nil {
		return RenderError(c, partials.ErrorMessage(i18n.T(c.Request().Context(), "netbird.could_not_get_settings", err.Error()), true))
	}

	p := partials.NewPaginationAndSort(0)
	return RenderView(c, computers_views.InventoryIndex(" | Deploy", computers_views.ComputerUpdates(c, p, agent, commonInfo, settings.AccessToken != "", h.IsAgentOffline(c)), commonInfo))
}

// ComputerListUpdates asks the agent for its available updates and the result of its last update run
func (h *Handler) ComputerListUpdates(c echo.Context) error {
	return h.renderComputerAvailableUpdates(c, "")
}

// ComputerUpdatePackages asks the agent to update the selected packages, or every package if none is selected
func (h *Handler) ComputerUpdatePackages(c echo.Context) error {
	commonInfo, err := h.GetCommonInfo(c)
	if err != nil {
		return err
	}

	agentID := c.Param("uuid")
	if agentID == "" {
		return RenderError(c, partials.ErrorMessage(i18n.T(c.Request().Context(), "agents.no_empty_id"), false))
	}

	// The agent must belong to the current organization and site
	if _, err := h.Model.GetAgentById(agentID, commonInfo); err != nil {
		return RenderError(c, partials.ErrorMessage(err.Error(), false))
	}

	if h.NATSConnection == nil || !h.NATSConnection.IsConnected() {
		return RenderError(c, partials.ErrorMessage(i18n.T(c.Request().Context(), "nats.not_connected"), false))
	}

	packages := []openuem_nats.AvailableUpdate{}
	if c.FormValue("updateAll") != "true" {
		form, err := c.FormParams()
		if err != nil {
			return RenderError(c, partials.ErrorMessage(err.Error(), false))
		}

		for _, value := range form["packages"] {
			p := openuem_nats.AvailableUpdate{}
			if err := json.Unmarshal([]byte(value), &p); err != nil {
				return RenderError(c, partials.ErrorMessage(err.Error(), false))
			}
			packages = append(packages, p)
		}

		if len(packages) == 0 {
			return RenderError(c, partials.ErrorMessage(i18n.T(c.Request().Context(), "package_updates.no_packages_selected"), false))
		}
	}

	if err := h.requestAgentPackageUpdates(agentID, packages); err != nil {
		return RenderError(c, partials.ErrorMessage(updateRequestErrorMessage(c, err), false))
	}

	return h.renderComputerAvailableUpdates(c, i18n.T(c.Request().Context(), "package_updates.requested"))
}

func (h *Handler) renderComputerAvailableUpdates(c echo.Context, successMessage string) error {
	commonInfo, err := h.GetCommonInfo(c)
	if err != nil {
		return err
	}

	agentID := c.Param("uuid")
	if agentID == "" {
		return RenderError(c, partials.ErrorMessage(i18n.T(c.Request().Context(), "agents.no_empty_id"), false))
	}

	// The agent must belong to the current organization and site
	if _, err := h.Model.GetAgentById(agentID, commonInfo); err != nil {
		return RenderError(c, partials.ErrorMessage(err.Error(), false))
	}

	if h.NATSConnection == nil || !h.NATSConnection.IsConnected() {
		return RenderError(c, partials.ErrorMessage(i18n.T(c.Request().Context(), "nats.not_connected"), false))
	}

	msg, err := h.NATSConnection.Request("agent.listpackageupdates."+agentID, nil, listPackageUpdatesTimeout)
	if err != nil {
		return RenderError(c, partials.ErrorMessage(updateRequestErrorMessage(c, err), false))
	}

	response := openuem_nats.AvailableUpdatesResponse{}
	if err := json.Unmarshal(msg.Data, &response); err != nil {
		return RenderError(c, partials.ErrorMessage(fmt.Sprintf("could not read the agent's response: %v", err), false))
	}

	return RenderView(c, computers_views.AvailableUpdates(agentID, &response, successMessage, commonInfo))
}
