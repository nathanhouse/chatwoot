import wootConstants from 'dashboard/constants/globals';
import { nextTick, ref, watch } from 'vue';

const { ASSIGNEE_TYPE, STATUS_TYPE } = wootConstants;

/**
 * Where the list has to be (assignee tab + status filter) for this conversation to appear in it.
 * Returns null when nothing should change: no conversation, the agent cannot see that tab,
 * or the list is already on the right tab and status.
 */
export const findListPlacement = ({
  conversation,
  currentUserId,
  activeTab,
  activeStatus,
  availableTabs,
}) => {
  if (!conversation?.id) return null;

  const assigneeId = conversation.meta?.assignee?.id;
  let assigneeTab = ASSIGNEE_TYPE.ALL;
  if (!assigneeId) assigneeTab = ASSIGNEE_TYPE.UNASSIGNED;
  else if (assigneeId === currentUserId) assigneeTab = ASSIGNEE_TYPE.ME;
  if (!availableTabs.includes(assigneeTab)) return null;

  const status =
    activeStatus === STATUS_TYPE.ALL ? activeStatus : conversation.status;
  if (assigneeTab === activeTab && status === activeStatus) return null;
  return { assigneeTab, status };
};

/**
 * Whenever the route's conversation changes (list click, search, notification, link, page load),
 * move the list to the tab and status that conversation belongs to and scroll its card into view.
 * It moves the list at most once per conversation, so a filter the agent changes by hand
 * afterwards is not switched back.
 */
export function useLocateOpenConversation({
  routeConversationId,
  selectedChat,
  conversationList,
  isScopedView,
  activeTab,
  activeStatus,
  currentUserId,
  availableTabs,
  moveList,
  scrollToIndex,
}) {
  const pendingId = ref(null);
  let hasSwitched = false;

  watch(
    routeConversationId,
    id => {
      pendingId.value = id ? Number(id) : null;
      hasSwitched = false;
    },
    { immediate: true }
  );

  watch(
    [pendingId, () => selectedChat.value?.id, () => conversationList.value],
    async () => {
      const id = pendingId.value;
      // Wait until the store has re-selected the conversation: a status switch empties the store
      // and clears the selection until the refetch lands.
      if (!id || isScopedView.value || selectedChat.value?.id !== id) return;

      const index = conversationList.value.findIndex(c => c.id === id);
      if (index !== -1) {
        pendingId.value = null;
        await nextTick();
        scrollToIndex(index);
        return;
      }

      // Move at most once per conversation. If a later update still doesn't include it (e.g. it is
      // past the loaded page), stop.
      const placement = hasSwitched
        ? null
        : findListPlacement({
            conversation: selectedChat.value,
            currentUserId: currentUserId.value,
            activeTab: activeTab.value,
            activeStatus: activeStatus.value,
            availableTabs: availableTabs.value,
          });
      if (!placement) {
        pendingId.value = null;
        return;
      }
      hasSwitched = true;
      moveList(placement);
    },
    { immediate: true }
  );
}
