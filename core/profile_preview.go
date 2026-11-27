package main

import (
	"context"
	"errors"
	"time"

	corecfg "github.com/VOD-Studio/ArkClash/core/internal/config"
	"github.com/metacubex/chi/render"
	"github.com/metacubex/http"
)

func getProfilePreview(w http.ResponseWriter, r *http.Request) {
	profile := r.URL.Query().Get("profile")
	if !corecfg.ValidProfileID(profile) {
		writeError(w, r, http.StatusBadRequest, corecfg.ErrPreviewInvalidProfile)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 15*time.Second)
	defer cancel()
	response, err := buildProfilePreview(ctx, profile)
	if err != nil {
		status := http.StatusBadRequest
		switch {
		case errors.Is(err, corecfg.ErrPreviewCoreUnavailable):
			status = http.StatusServiceUnavailable
		case errors.Is(err, corecfg.ErrPreviewNotFound):
			status = http.StatusNotFound
		}
		writeError(w, r, status, err)
		return
	}
	render.JSON(w, r, response)
}

func buildProfilePreview(ctx context.Context, profile string) (corecfg.PreviewResponse, error) {
	spec, ready := eng.ConfigSpec()
	if !ready {
		return corecfg.PreviewResponse{}, corecfg.ErrPreviewCoreUnavailable
	}
	built, err := corecfg.BuildPreview(ctx, spec.Options, profile)
	if err != nil {
		return corecfg.PreviewResponse{}, err
	}

	var (
		applied        bool
		bootID         string
		configRevision uint64
		runningProfile string
	)
	if err := eng.withState(func(tx *stateTx) error {
		if !eng.running {
			return corecfg.ErrPreviewCoreUnavailable
		}
		applied = corecfg.PreviewMatchesCurrent(eng.current, built.Options, built.Hash)
		bootID = eng.bootID
		configRevision = eng.configRevision
		runningProfile = eng.current.Profile
		return nil
	}); err != nil {
		return corecfg.PreviewResponse{}, err
	}

	return corecfg.PreviewResponse{
		Profile:         profile,
		BootID:          bootID,
		ConfigRevision:  configRevision,
		ContentRevision: built.Meta.ContentRevision,
		ContentHash:     built.ShortHash(),
		Applied:         applied,
		RunningProfile:  runningProfile,
		CustomRules:     built.Options.CustomRules,
		ScriptIdentity:  built.Options.Script.Identity,
		YAML:            built.YAML,
	}, nil
}
