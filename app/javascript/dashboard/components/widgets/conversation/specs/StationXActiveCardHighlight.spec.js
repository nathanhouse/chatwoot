// StationX: the open conversation in the list must stand out (Alan 2026-11-04).
// Both card layouts (compact list + expanded wide-screen list) get the same highlight.
import { shallowMount } from '@vue/test-utils';
import ConversationCardExpanded from 'dashboard/components-next/Conversation/ConversationCard/ConversationCardExpanded.vue';
import ConversationCard from '../ConversationCard.vue';

const HIGHLIGHT = [
  '!bg-n-blue-4',
  'shadow-[inset_0.1875rem_0_0_0_theme(colors.n.brand)]',
];
const UPSTREAM_FAINT_GREY = ['bg-n-background', 'bg-n-alpha-1'];

const chat = {
  id: 1,
  labels: [],
  messages: [],
  priority: null,
  unread_count: 0,
  timestamp: 1700000000,
  created_at: 1700000000,
};
const currentContact = {
  name: 'Jane Doe',
  thumbnail: '',
  availability_status: 'offline',
};

describe.each([
  ['ConversationCard', ConversationCard],
  ['ConversationCardExpanded', ConversationCardExpanded],
])('%s open-ticket highlight', (_name, Component) => {
  const mountCard = isActiveChat =>
    shallowMount(Component, {
      props: { chat, currentContact, inbox: { id: 1 }, isActiveChat },
      global: { stubs: { 'fluent-icon': true } },
    });

  it('paints the open conversation blue with a left bar, not faint grey', () => {
    const classes = mountCard(true).classes();

    HIGHLIGHT.forEach(cls => expect(classes).toContain(cls));
    UPSTREAM_FAINT_GREY.forEach(cls => expect(classes).not.toContain(cls));
  });

  it('leaves the other conversations unhighlighted', () => {
    const classes = mountCard(false).classes();

    HIGHLIGHT.forEach(cls => expect(classes).not.toContain(cls));
  });
});
