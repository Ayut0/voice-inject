package ipc

import "testing"

func TestBusPublishWithNoSubscribersDoesNotBlock(t *testing.T) {
	b := NewBus()
	// Must return immediately; a hang here fails via test timeout.
	b.Publish(StateEvent(EventIdle))
}

func TestBusDeliversToAllSubscribers(t *testing.T) {
	b := NewBus()
	_, ch1 := b.Subscribe()
	_, ch2 := b.Subscribe()

	b.Publish(StateEvent(EventRecording))

	for i, ch := range []<-chan Event{ch1, ch2} {
		ev := <-ch
		if ev.Name != EventRecording {
			t.Errorf("subscriber %d: got %q, want %q", i, ev.Name, EventRecording)
		}
	}
}

func TestBusUnsubscribeClosesChannel(t *testing.T) {
	b := NewBus()
	id, ch := b.Subscribe()
	b.Unsubscribe(id)
	if _, ok := <-ch; ok {
		t.Error("channel should be closed after Unsubscribe")
	}
	b.Unsubscribe(id) // idempotent: must not panic
}

func TestBusDropsWhenSubscriberBufferFull(t *testing.T) {
	b := NewBus()
	_, ch := b.Subscribe()
	// Fill past the buffer; Publish must never block.
	for i := 0; i < subscriberBuffer+10; i++ {
		b.Publish(StateEvent(EventIdle))
	}
	// Drain: we should get exactly subscriberBuffer events.
	got := 0
	for {
		select {
		case <-ch:
			got++
		default:
			if got != subscriberBuffer {
				t.Errorf("got %d buffered events, want %d", got, subscriberBuffer)
			}
			return
		}
	}
}
