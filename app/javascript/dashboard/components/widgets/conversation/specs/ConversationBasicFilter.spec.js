import { shallowMount } from '@vue/test-utils';
import { createStore } from 'vuex';
import ConversationBasicFilter from '../ConversationBasicFilter.vue';

const updateUISettings = vi.fn();
let savedSettings = {};

vi.mock('dashboard/composables/useUISettings', async () => {
  const { ref } = await import('vue');
  return {
    useUISettings: () => ({
      uiSettings: ref(savedSettings),
      updateUISettings,
    }),
  };
});

// The list shows Resolved because it followed an opened conversation.
const changeSortWhileListShowsResolved = () => {
  const store = createStore({
    getters: {
      getChatStatusFilter: () => 'resolved',
      getChatSortFilter: () => 'last_activity_at_desc',
    },
    actions: { setChatSortFilter: vi.fn(), setChatStatusFilter: vi.fn() },
  });
  const wrapper = shallowMount(ConversationBasicFilter, {
    props: { isOnExpandedLayout: false },
    global: {
      plugins: [store],
      mocks: { $t: key => key },
    },
  });

  // The sort menu only renders inside the open dropdown, which does not render reliably in jsdom;
  // call the component's own sort handler instead (the path the sort menu's update event takes).
  wrapper.vm.$.setupState.handleSortChange('created_at_desc');
};

describe('ConversationBasicFilter', () => {
  beforeEach(() => updateUISettings.mockClear());

  it('keeps the saved status when only the sort changes', () => {
    savedSettings = {
      conversations_filter_by: {
        status: 'open',
        order_by: 'last_activity_at_desc',
      },
    };
    changeSortWhileListShowsResolved();

    expect(updateUISettings).toHaveBeenCalledWith({
      conversations_filter_by: {
        status: 'open',
        order_by: 'created_at_desc',
      },
    });
  });

  it('saves the default status, not the shown one, when no status was ever saved', () => {
    savedSettings = {};
    changeSortWhileListShowsResolved();

    expect(updateUISettings).toHaveBeenCalledWith({
      conversations_filter_by: {
        status: 'open',
        order_by: 'created_at_desc',
      },
    });
  });
});
