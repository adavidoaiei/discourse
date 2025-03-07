import DiscourseRoute from "discourse/routes/discourse";
import I18n from "I18n";
import { action } from "@ember/object";
import { inject as service } from "@ember/service";
import GroupAddMembersModal from "discourse/components/modal/group-add-members";
import CreateInvite from "discourse/components/modal/create-invite";

export default DiscourseRoute.extend({
  modal: service(),

  titleToken() {
    return I18n.t("groups.members.title");
  },

  model(params) {
    this._params = params;
    return this.modelFor("group");
  },

  setupController(controller, model) {
    controller.setProperties({
      model,
      filterInput: this._params.filter,
      showing: "members",
    });

    controller.reloadMembers(true);
  },

  @action
  showAddMembersModal() {
    this.modal.show(GroupAddMembersModal, { model: this.modelFor("group") });
  },

  @action
  showInviteModal() {
    const group = this.modelFor("group");
    this.modal.show(CreateInvite, { model: { groupIds: [group.id] } });
  },

  @action
  didTransition() {
    this.controllerFor("group-index").set("filterInput", this._params.filter);
    return true;
  },
});
