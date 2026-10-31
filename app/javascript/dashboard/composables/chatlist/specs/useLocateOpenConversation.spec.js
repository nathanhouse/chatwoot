import { computed, nextTick, ref } from 'vue';
import {
  findListPlacement,
  useLocateOpenConversation,
} from '../useLocateOpenConversation';

const ME = 1;
const ALL_TABS = ['me', 'unassigned', 'all'];
const mine = { id: 7, status: 'open', meta: { assignee: { id: ME } } };

describe('findListPlacement', () => {
  const place = (conversation, overrides = {}) =>
    findListPlacement({
      conversation,
      currentUserId: ME,
      activeTab: 'me',
      activeStatus: 'open',
      availableTabs: ALL_TABS,
      ...overrides,
    });

  it('moves to Mine when the conversation is assigned to me', () => {
    expect(place(mine, { activeTab: 'unassigned' })).toEqual({
      assigneeTab: 'me',
      status: 'open',
    });
  });

  it('moves to All when it is assigned to someone else', () => {
    const theirs = { ...mine, meta: { assignee: { id: 2 } } };
    expect(place(theirs)).toEqual({ assigneeTab: 'all', status: 'open' });
  });

  it('moves to Unassigned when nobody is assigned', () => {
    const nobody = { ...mine, meta: {} };
    expect(place(nobody)).toEqual({
      assigneeTab: 'unassigned',
      status: 'open',
    });
  });

  it('switches the status filter to the conversation status', () => {
    expect(place({ ...mine, status: 'resolved' })).toEqual({
      assigneeTab: 'me',
      status: 'resolved',
    });
  });

  it('keeps the All status filter, which already shows every status', () => {
    expect(
      place(
        { ...mine, status: 'resolved' },
        { activeTab: 'unassigned', activeStatus: 'all' }
      )
    ).toEqual({ assigneeTab: 'me', status: 'all' });
  });

  it('does nothing when the agent cannot see the tab it belongs to', () => {
    const theirs = { ...mine, meta: { assignee: { id: 2 } } };
    expect(place(theirs, { availableTabs: ['me', 'unassigned'] })).toBeNull();
  });

  it('does nothing when the tab and status already match', () => {
    expect(place(mine)).toBeNull();
  });

  it('does nothing without a selected conversation', () => {
    expect(place({})).toBeNull();
  });
});

describe('useLocateOpenConversation', () => {
  const setup = ({ list = [], selected = mine, scoped = false } = {}) => {
    const routeConversationId = ref(undefined);
    const selectedChat = ref({});
    const conversationList = ref(list);
    const activeTab = ref('unassigned');
    const activeStatus = ref('open');
    // One call per move, so ChatList can fetch once when both the tab and the status change.
    const moveList = vi.fn(({ assigneeTab, status }) => {
      activeTab.value = assigneeTab;
      activeStatus.value = status;
    });
    const scrollToIndex = vi.fn();

    useLocateOpenConversation({
      routeConversationId,
      selectedChat,
      conversationList,
      isScopedView: computed(() => scoped),
      activeTab,
      activeStatus,
      currentUserId: computed(() => ME),
      availableTabs: computed(() => ALL_TABS),
      moveList,
      scrollToIndex,
    });

    const open = async () => {
      routeConversationId.value = String(selected.id);
      selectedChat.value = selected;
      await nextTick();
      await nextTick();
    };

    return {
      open,
      selectedChat,
      conversationList,
      activeStatus,
      moveList,
      scrollToIndex,
    };
  };

  it('switches to the right tab, then scrolls to the card once it is listed', async () => {
    const other = { id: 3, status: 'open', meta: {} };
    const t = setup({ list: [other] });

    await t.open();
    expect(t.moveList).toHaveBeenCalledWith({
      assigneeTab: 'me',
      status: 'open',
    });

    t.conversationList.value = [other, mine];
    await nextTick();
    await nextTick();
    expect(t.scrollToIndex).toHaveBeenCalledWith(1);
  });

  it('only scrolls when the conversation is already listed', async () => {
    const t = setup({ list: [mine] });

    await t.open();
    expect(t.moveList).not.toHaveBeenCalled();
    expect(t.scrollToIndex).toHaveBeenCalledWith(0);
  });

  it('leaves label, team, folder and filtered views alone', async () => {
    const t = setup({ scoped: true });

    await t.open();
    expect(t.moveList).not.toHaveBeenCalled();
    expect(t.scrollToIndex).not.toHaveBeenCalled();
  });

  it('does not undo a status filter the agent picks by hand afterwards', async () => {
    const resolved = { ...mine, status: 'resolved' };
    const t = setup({ list: [], selected: resolved });

    await t.open();
    expect(t.moveList).toHaveBeenCalledWith({
      assigneeTab: 'me',
      status: 'resolved',
    });
    t.conversationList.value = [resolved];
    await nextTick();
    await nextTick();
    expect(t.scrollToIndex).toHaveBeenCalledWith(0);

    // The agent picks Open by hand: the list resets and the store re-selects the conversation.
    t.activeStatus.value = 'open';
    t.conversationList.value = [];
    t.selectedChat.value = {};
    await nextTick();
    t.selectedChat.value = resolved;
    await nextTick();
    await nextTick();
    expect(t.moveList).toHaveBeenCalledTimes(1);
  });

  it('switches once and gives up if the conversation still is not listed', async () => {
    const t = setup({ list: [] });

    await t.open();
    t.conversationList.value = [{ id: 3, status: 'open', meta: {} }];
    await nextTick();
    t.selectedChat.value = { ...mine };
    await nextTick();
    await nextTick();
    expect(t.moveList).toHaveBeenCalledTimes(1);
    expect(t.scrollToIndex).not.toHaveBeenCalled();
  });
});
