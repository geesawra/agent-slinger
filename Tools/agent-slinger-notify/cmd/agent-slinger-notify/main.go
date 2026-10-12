// agent-slinger-notify is an optional user-operated passive Paseo -> Pushover sidecar.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/geesawra/oesap/Tools/agent-slinger-notify/config"
	"github.com/geesawra/oesap/Tools/agent-slinger-notify/deeplink"
	"github.com/geesawra/oesap/Tools/agent-slinger-notify/notify"
	"github.com/geesawra/oesap/Tools/agent-slinger-notify/paseo"
	"github.com/geesawra/oesap/Tools/agent-slinger-notify/pushover"
	"github.com/geesawra/oesap/Tools/agent-slinger-notify/state"
)

func main() {
	log := slog.New(slog.NewJSONHandler(os.Stderr, nil))
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := execute(ctx, os.Args[1:], log); err != nil && !errors.Is(err, context.Canceled) {
		log.Error("sidecar_stopped", "error", err.Error())
		os.Exit(1)
	}
}

type connection interface {
	ServerIdentity() string
	ServerHostname() string
	Events() <-chan notify.Event
	Err() error
	FetchAgent(context.Context, string) (paseo.Agent, error)
	Close() error
}
type providerClient interface {
	notify.Sender
	ValidateRecipient(context.Context) pushover.Outcome
}
type dependencies struct {
	connect  func(context.Context, paseo.Options) (connection, error)
	provider func(config.Secrets, string) providerClient
}

func defaults() dependencies {
	return dependencies{connect: func(ctx context.Context, o paseo.Options) (connection, error) { return paseo.Connect(ctx, o) }, provider: func(s config.Secrets, d string) providerClient { return pushover.New(s.Token, s.User, d) }}
}
func execute(ctx context.Context, args []string, log *slog.Logger) error {
	return executeWith(ctx, args, log, defaults())
}
func executeWith(ctx context.Context, args []string, log *slog.Logger, deps dependencies) error {
	if len(args) == 0 {
		return errors.New("usage: agent-slinger-notify run|check|test [--agent-id ID] [--workspace-id ID]; settings come from environment")
	}
	command := args[0]
	if command != "run" && command != "check" && command != "test" {
		return errors.New("unknown command; use run, check or test")
	}
	flags := flag.NewFlagSet(command, flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	agentID := flags.String("agent-id", "", "test agent identifier")
	workspaceID := flags.String("workspace-id", "", "optional expected workspace for test")
	if flags.Parse(args[1:]) != nil || flags.NArg() != 0 {
		return errors.New("invalid arguments; settings come from environment")
	}
	if command != "test" && (*agentID != "" || *workspaceID != "") {
		return errors.New("agent and workspace options are only supported by test")
	}
	if command == "test" && !deeplink.ValidID(*agentID) {
		return errors.New("test requires --agent-id")
	}
	c, secrets, err := config.Load()
	if err != nil {
		return err
	}
	provider := deps.provider(secrets, c.Pushover.Device)
	log.Info("policy_configured", "delivery_mode", c.DeliveryMode, "content", c.Content, "presence_suppression", false)
	validateCtx, cancel := context.WithTimeout(ctx, 25*time.Second)
	outcome := provider.ValidateRecipient(validateCtx)
	cancel()
	if ctx.Err() != nil {
		return ctx.Err()
	}
	if !outcome.Accepted {
		return fmt.Errorf("Pushover recipient check failed: %s", outcome.Code)
	}
	log.Info("recipient_validated")
	if command == "run" {
		return run(ctx, c, secrets, provider, log, deps.connect)
	}
	client, err := deps.connect(ctx, paseo.Options{URL: c.Paseo.URL, PairingLink: c.Paseo.PairingLink, Password: secrets.Password, ExpectedServerID: c.Paseo.ExpectedServerID})
	if err != nil {
		return err
	}
	defer func() {
		if client.Close() != nil {
			log.Warn("subscription_release_unconfirmed")
		}
	}()
	log.Info("connection_ready", "protocol_revision", paseo.SourceRevision, "passive_subscription", true)
	if command == "check" {
		log.Info("check_passed", "messages_sent", 0)
		return nil
	}
	lookupCtx, lookupCancel := context.WithTimeout(ctx, 5*time.Second)
	agent, err := client.FetchAgent(lookupCtx, *agentID)
	lookupCancel()
	if err != nil {
		return err
	}
	if *workspaceID != "" && agent.WorkspaceID != *workspaceID {
		return errors.New("test workspace assertion differs from authoritative agent workspace")
	}
	action, err := deeplink.Build(deeplink.Target{ServerID: client.ServerIdentity(), WorkspaceID: agent.WorkspaceID, AgentID: agent.ID})
	if err != nil {
		return err
	}
	outcome = provider.Send(ctx, pushover.Message{Title: notify.DisplayTitle(agent.Title, agent.ID, "test alert"), HTML: true, Body: notify.DisplayBody(notify.ServerLabel(c.Paseo.ServerName, client.ServerHostname(), client.ServerIdentity()), client.ServerIdentity(), "Test notification: open this agent session with the action below."), URL: action, URLTitle: "Open Agent Slinger"})
	if ctx.Err() != nil {
		return ctx.Err()
	}
	if !outcome.Accepted {
		return fmt.Errorf("test alert not confirmed (%s); an ambiguous request may already have been accepted", outcome.Code)
	}
	log.Info("test_alert_accepted", "device_display_confirmed", false)
	return nil
}
func run(ctx context.Context, c config.Config, secrets config.Secrets, provider notify.Sender, log *slog.Logger, connect func(context.Context, paseo.Options) (connection, error)) error {

	var store *state.Store
	defer func() {
		if store != nil {
			_ = store.Close()
		}
	}()
	var worker *notify.Worker
	var policy notify.Policy
	expectedServerID := c.Paseo.ExpectedServerID
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	backoff := 5 * time.Second
	for {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		client, connectErr := connect(ctx, paseo.Options{URL: c.Paseo.URL, PairingLink: c.Paseo.PairingLink, Password: secrets.Password, ExpectedServerID: expectedServerID})
		if connectErr != nil {
			if ctx.Err() != nil {
				return ctx.Err()
			}
			if paseo.Permanent(connectErr) {
				return connectErr
			}
			log.Warn("connection_unavailable", "coverage_gap", true, "replay_guaranteed", false)

		} else {
			actualServerID := client.ServerIdentity()
			if !deeplink.ValidID(actualServerID) || (expectedServerID != "" && actualServerID != expectedServerID) {
				_ = client.Close()
				return errors.New("Paseo server identity changed or is invalid")
			}
			if store == nil {
				// Persist only after authenticated discovery; reconnects remain pinned to this identity.
				expectedServerID = actualServerID
				scope := state.Key(actualServerID, secrets.User, c.Pushover.Device, c.Content, c.DeliveryMode)
				var err error
				legacyScopes := []string{}
				if c.Content == "paseo-preview" {
					legacyScopes = append(legacyScopes, state.Key(actualServerID, secrets.User, c.Pushover.Device, "generic", c.DeliveryMode))
				}
				store, err = state.Open(c.StateDir, scope, c.MaxPending, legacyScopes...)
				if err != nil {
					_ = client.Close()
					return err
				}
				policy = notify.Policy{Mode: c.DeliveryMode, Content: c.Content, ServerID: actualServerID, TTL: time.Duration(c.EventTTLSeconds) * time.Second}
				worker = &notify.Worker{Store: store, Sender: provider, Now: time.Now, Report: func(code string, n int) { log.Info("sender_health", "status", code, "count", n) }}
				log.Info("outbox_ready", "pending", store.Count(), "max_pending", c.MaxPending)
			}
			policy.ServerName = notify.ServerLabel(c.Paseo.ServerName, client.ServerHostname(), actualServerID)
			backoff = 5 * time.Second
			log.Info("connection_ready", "protocol_revision", paseo.SourceRevision, "passive_subscription", true, "pending", store.Count())
			err := observe(ctx, client, store, policy, worker, ticker.C, log)
			if closeErr := client.Close(); closeErr != nil && ctx.Err() != nil {
				log.Warn("subscription_release_unconfirmed")
			}
			if ctx.Err() != nil {
				return ctx.Err()
			}
			if err != nil {
				return err
			}
			if paseo.Permanent(client.Err()) {
				return client.Err()
			}
			log.Warn("attention_stream_coverage_gap", "replay_guaranteed", false)
		}
		timer := time.NewTimer(backoff)
	wait:
		for {
			select {
			case <-ctx.Done():
				timer.Stop()
				return ctx.Err()
			case <-timer.C:
				break wait
			case <-ticker.C:
				if worker == nil {
					continue
				}
				if err := worker.Step(ctx); err != nil {
					timer.Stop()
					return err
				}
			}
		}
		if backoff < time.Minute {
			backoff *= 2
			if backoff > time.Minute {
				backoff = time.Minute
			}
		}
	}
}
func observe(ctx context.Context, client connection, store *state.Store, policy notify.Policy, worker *notify.Worker, ticks <-chan time.Time, log *slog.Logger) error {
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-ticks:
			if err := worker.Step(ctx); err != nil {
				return err
			}
		case event, ok := <-client.Events():
			if !ok {
				return nil
			}

			// Labels are authoritative metadata; preview text remains tied to the attention event.
			if (event.Reason == "finished" || event.Reason == "permission") && event.Notification != nil {
				if event.Notification.Data.ServerID != client.ServerIdentity() || event.Notification.Data.AgentID != event.AgentID || event.Notification.Data.Reason != event.Reason {
					log.Warn("dropped_target", "reason", "metadata_mismatch")
					continue
				}
				lookupCtx, cancel := context.WithTimeout(ctx, 3*time.Second)
				agent, err := client.FetchAgent(lookupCtx, event.AgentID)
				cancel()
				if err == nil && agent.ID == event.AgentID {
					event.AgentTitle = agent.Title
					if event.Notification.Data.WorkspaceID == "" {
						event.Notification.Data.WorkspaceID = agent.WorkspaceID
					}
				} else {
					log.Warn("agent_context_unavailable")
					if event.Notification.Data.WorkspaceID == "" {
						log.Warn("dropped_target", "reason", "workspace_unresolved")
						continue
					}
				}
			}
			item, err := policy.Prepare(event, time.Now())
			if err != nil {
				log.Warn("dropped_target", "reason", "invalid_payload_or_route")
				continue
			}
			if item == nil {
				continue
			}
			queued, dropped, err := store.Enqueue(*item, time.Now())
			if err != nil {
				return err
			}
			if dropped > 0 {
				log.Warn("outbox_dropped", "count", dropped)
			}
			if queued {
				log.Info("outbox_queued", "pending", store.Count())
			} else {
				log.Info("attention_deduplicated")
			}
		}
	}
}
