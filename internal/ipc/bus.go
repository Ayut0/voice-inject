package ipc

import "sync"

// subscriberBuffer is the per-subscriber event buffer. Publish drops
// events for subscribers whose buffer is full rather than blocking the
// daemon's state machine.
const subscriberBuffer = 16

// Bus fans events out to subscribers. Safe for concurrent use.
type Bus struct {
	mu   sync.Mutex
	next int
	subs map[int]chan Event
}

func NewBus() *Bus {
	return &Bus{subs: make(map[int]chan Event)}
}

func (b *Bus) Subscribe() (int, <-chan Event) {
	b.mu.Lock()
	defer b.mu.Unlock()
	id := b.next
	b.next++
	ch := make(chan Event, subscriberBuffer)
	b.subs[id] = ch
	return id, ch
}

func (b *Bus) Unsubscribe(id int) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if ch, ok := b.subs[id]; ok {
		delete(b.subs, id)
		close(ch)
	}
}

// Publish never blocks: subscribers with a full buffer miss the event.
func (b *Bus) Publish(ev Event) {
	b.mu.Lock()
	defer b.mu.Unlock()
	for _, ch := range b.subs {
		select {
		case ch <- ev:
		default:
		}
	}
}
