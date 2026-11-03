package handlers

import (
	"errors"
	"log"
	"net/http"

	"github.com/labstack/echo/v4"
	"github.com/open-uem/openuem-console/internal/taskfiles"
)

const (
	// agentCertificateCommonName is the common name of the certificate shared by the agents
	agentCertificateCommonName = "OpenUEM Agent"
	// AgentIDHeader identifies the agent that downloads a file
	AgentIDHeader = "X-OpenUEM-Agent"
)

// AgentFile serves a file uploaded for a task. Only agents can download it: they present
// the agent certificate issued by OpenUEM's CA and their id, and the file's profile must
// be applied to that agent, using the same rules as when profiles are sent to agents.
func (h *Handler) AgentFile(c echo.Context) error {
	if h.TaskFiles == nil {
		return echo.NewHTTPError(http.StatusNotFound)
	}

	cert, err := clientCertificate(c)
	if err != nil {
		return err
	}
	if _, err := getIssuerFromCert(cert, h.CACert); err != nil || cert.Subject.CommonName != agentCertificateCommonName {
		return echo.NewHTTPError(http.StatusUnauthorized, "Certificate did not pass verification")
	}

	file, err := taskfiles.NewFile(c.Param("profile"), c.Param("hash"), c.Param("name"))
	if err != nil {
		return echo.NewHTTPError(http.StatusNotFound)
	}

	agentID := c.Request().Header.Get(AgentIDHeader)
	applies, err := h.Model.ProfileAppliesToAgent(file.ProfileID, agentID)
	if err != nil {
		log.Printf("[ERROR]: could not check if profile %d applies to agent %s, reason: %v", file.ProfileID, agentID, err)
		return echo.NewHTTPError(http.StatusInternalServerError)
	}
	if !applies {
		log.Printf("[WARN]: agent %q requested a file of profile %d, which isn't applied to it", agentID, file.ProfileID)
		return echo.NewHTTPError(http.StatusForbidden)
	}

	path, err := h.TaskFiles.Path(file)
	if errors.Is(err, taskfiles.ErrNotFound) || errors.Is(err, taskfiles.ErrInvalidFile) {
		return echo.NewHTTPError(http.StatusNotFound)
	}
	if err != nil {
		return echo.NewHTTPError(http.StatusInternalServerError)
	}

	return c.Attachment(path, file.Name)
}
