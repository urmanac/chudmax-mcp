package main

import (
	"context"
	"log"
	"time"

	sourcev1 "github.com/fluxcd/source-controller/api/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/config"
)

// newClient builds the k8s client the watcher reads with. In the pod this is
// the in-cluster config; locally, a KUBECONFIG. The sidecar only ever reads:
// the Role it runs under is namespaced and grants get, watch on the one
// ExternalArtifact -- exactly the verbs these calls produce on the API server.
func newClient() (client.WithWatch, *runtime.Scheme, error) {
	scheme := runtime.NewScheme()
	if err := clientgoscheme.AddToScheme(scheme); err != nil {
		return nil, nil, err
	}
	if err := sourcev1.AddToScheme(scheme); err != nil {
		return nil, nil, err
	}
	c, err := client.NewWithWatch(config.GetConfigOrDie(), client.Options{Scheme: scheme})
	if err != nil {
		return nil, nil, err
	}
	return c, scheme, nil
}

// runWatch keeps <root>/current on the newest verified artifact of the one
// ExternalArtifact this sidecar is allowed to read. It reads the object once
// at startup -- which is what covers a missed event after a restart -- then
// watches it, re-reads every resync as a fallback for a silently dropped
// stream, and reconnects when the watch ends. Every observed change to
// status.artifact runs FetchAndSwap; a digest the sidecar already serves is a
// logged no-op.
func runWatch(ctx context.Context, c client.WithWatch, _ *runtime.Scheme, ns, name, root string,
	o CoreOpts, resync time.Duration, watchOpts ...client.ListOption) error {

	key := types.NamespacedName{Namespace: ns, Name: name}
	o.Source = "externalartifact " + ns + "/" + name

	served := "" // digest behind current as far as this process knows
	observe := func(ea *sourcev1.ExternalArtifact) error {
		a := ea.GetArtifact()
		if a == nil {
			log.Printf("watch: %s/%s has no artifact yet", ns, name)
			return nil
		}
		if a.Digest == served {
			return nil
		}
		o.Revision = a.Revision
		o.Produced = rfc3339(a.LastUpdateTime)
		swapped, err := FetchAndSwap(ctx, a.URL, a.Digest, root, o)
		if err != nil {
			// The previous tree keeps serving; the stream keeps running and
			// the next observation retries.
			log.Printf("watch: fetch of digest=%s failed, previous tree kept: %v", shortDigest(a.Digest), err)
			return nil
		}
		served = a.Digest
		log.Printf("watch: digest=%s revision=%q swapped=%v", shortDigest(a.Digest), a.Revision, swapped)
		return nil
	}

	for {
		ea := &sourcev1.ExternalArtifact{}
		if err := c.Get(ctx, key, ea); err != nil {
			return err
		}
		if err := observe(ea); err != nil {
			return err
		}

		w, err := c.Watch(ctx, &sourcev1.ExternalArtifactList{}, watchOpts...)
		if err != nil {
			return err
		}
		log.Printf("watch: stream open")

		timer := time.NewTimer(resync)
	keepLoop:
		for {
			select {
			case <-ctx.Done():
				w.Stop()
				return nil
			case <-timer.C:
				// Fallback for a silently dropped stream: re-read and compare.
				again := &sourcev1.ExternalArtifact{}
				if err := c.Get(ctx, key, again); err != nil {
					log.Printf("watch: resync read failed: %v", err)
				} else if err := observe(again); err != nil {
					return err
				}
				timer.Reset(resync)
			case ev, ok := <-w.ResultChan():
				if !ok {
					log.Printf("watch: stream ended, reconnecting")
					w.Stop()
					break keepLoop
				}
				ea, ok := ev.Object.(*sourcev1.ExternalArtifact)
				if !ok {
					continue
				}
				if err := observe(ea); err != nil {
					w.Stop()
					return err
				}
			}
		}
		if ctx.Err() != nil {
			return nil
		}
		// Back off before the reconnect read: one resync period, so a stream
		// that keeps dying cannot turn into a hot loop, and so a missed event
		// is picked up at most one resync late.
		select {
		case <-ctx.Done():
			return nil
		case <-time.After(resync):
		}
	}
}

func rfc3339(t metav1.Time) string {
	return t.Time.UTC().Format(time.RFC3339)
}
