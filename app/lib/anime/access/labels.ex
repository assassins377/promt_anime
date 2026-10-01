defmodule Anime.Access.Labels do
  @moduledoc "Localized display labels; permission codes and stored custom role names never change."
  use Gettext, backend: AnimeWeb.Gettext
  alias Anime.Access.Catalog

  def role_name(%{system: true, code: code, name: code}), do: system_role_name(code)

  def role_name(%{role_name: name, role_code: code, role_system: system}),
    do: role_name(%{name: name, code: code, system: system})

  def role_name(%{name: name}), do: name

  defp system_role_name("user"), do: dgettext("access", "role.user")
  defp system_role_name("comment_moderator"), do: dgettext("access", "role.comment_moderator")
  defp system_role_name("content_editor"), do: dgettext("access", "role.content_editor")
  defp system_role_name("admin"), do: dgettext("access", "role.admin")
  defp system_role_name("owner"), do: dgettext("access", "role.owner")
  defp system_role_name(code), do: code

  def group_name(:admin), do: group_name("admin")
  def group_name("admin"), do: dgettext("access", "group.admin")
  def group_name(:users), do: group_name("users")
  def group_name("users"), do: dgettext("access", "group.users")
  def group_name(:roles), do: group_name("roles")
  def group_name("roles"), do: dgettext("access", "group.roles")
  def group_name(:moderation), do: group_name("moderation")
  def group_name("moderation"), do: dgettext("access", "group.moderation")
  def group_name(:content), do: group_name("content")
  def group_name("content"), do: dgettext("access", "group.content")
  def group_name(:video), do: group_name("video")
  def group_name("video"), do: dgettext("access", "group.video")
  def group_name(:blog), do: group_name("blog")
  def group_name("blog"), do: dgettext("access", "group.blog")
  def group_name(:announcements), do: group_name("announcements")
  def group_name("announcements"), do: dgettext("access", "group.announcements")
  def group_name(:feedback), do: group_name("feedback")
  def group_name("feedback"), do: dgettext("access", "group.feedback")
  def group_name(:billing), do: group_name("billing")
  def group_name("billing"), do: dgettext("access", "group.billing")
  def group_name(:audit), do: group_name("audit")
  def group_name("audit"), do: dgettext("access", "group.audit")
  def group_name(:settings), do: group_name("settings")
  def group_name("settings"), do: dgettext("access", "group.settings")
  def group_name(:system), do: group_name("system")
  def group_name("system"), do: dgettext("access", "group.system")
  def group_name(_), do: gettext("Неизвестная область")

  def permission_name("admin.panel.access"), do: dgettext("access", "admin.panel.access")
  def permission_name("admin.dashboard.view"), do: dgettext("access", "admin.dashboard.view")
  def permission_name("admin.stats.view"), do: dgettext("access", "admin.stats.view")
  def permission_name("users.user.view"), do: dgettext("access", "users.user.view")
  def permission_name("users.user.edit"), do: dgettext("access", "users.user.edit")
  def permission_name("users.user.ban"), do: dgettext("access", "users.user.ban")
  def permission_name("users.user.unban"), do: dgettext("access", "users.user.unban")
  def permission_name("users.user.delete"), do: dgettext("access", "users.user.delete")
  def permission_name("users.role.assign"), do: dgettext("access", "users.role.assign")
  def permission_name("users.session.revoke"), do: dgettext("access", "users.session.revoke")
  def permission_name("users.activity.view"), do: dgettext("access", "users.activity.view")
  def permission_name("roles.role.view"), do: dgettext("access", "roles.role.view")
  def permission_name("roles.role.create"), do: dgettext("access", "roles.role.create")
  def permission_name("roles.role.edit"), do: dgettext("access", "roles.role.edit")
  def permission_name("roles.role.delete"), do: dgettext("access", "roles.role.delete")
  def permission_name("roles.permission.view"), do: dgettext("access", "roles.permission.view")
  def permission_name("roles.matrix.edit"), do: dgettext("access", "roles.matrix.edit")
  def permission_name("moderation.report.view"), do: dgettext("access", "moderation.report.view")

  def permission_name("moderation.report.resolve"),
    do: dgettext("access", "moderation.report.resolve")

  def permission_name("moderation.comment.view"),
    do: dgettext("access", "moderation.comment.view")

  def permission_name("moderation.comment.edit"),
    do: dgettext("access", "moderation.comment.edit")

  def permission_name("moderation.comment.hide"),
    do: dgettext("access", "moderation.comment.hide")

  def permission_name("moderation.comment.delete"),
    do: dgettext("access", "moderation.comment.delete")

  def permission_name("moderation.stopword.edit"),
    do: dgettext("access", "moderation.stopword.edit")

  def permission_name("moderation.content.view"),
    do: dgettext("access", "moderation.content.view")

  def permission_name("moderation.content.review"),
    do: dgettext("access", "moderation.content.review")

  def permission_name("moderation.donation_comment.moderate"),
    do: dgettext("access", "moderation.donation_comment.moderate")

  def permission_name("content.anime.view"), do: dgettext("access", "content.anime.view")
  def permission_name("content.anime.create"), do: dgettext("access", "content.anime.create")
  def permission_name("content.anime.edit"), do: dgettext("access", "content.anime.edit")
  def permission_name("content.anime.delete"), do: dgettext("access", "content.anime.delete")
  def permission_name("content.anime.publish"), do: dgettext("access", "content.anime.publish")
  def permission_name("content.draft.view"), do: dgettext("access", "content.draft.view")
  def permission_name("content.season.manage"), do: dgettext("access", "content.season.manage")
  def permission_name("content.episode.manage"), do: dgettext("access", "content.episode.manage")
  def permission_name("content.genre.manage"), do: dgettext("access", "content.genre.manage")

  def permission_name("content.category.manage"),
    do: dgettext("access", "content.category.manage")

  def permission_name("content.stage.manage"), do: dgettext("access", "content.stage.manage")
  def permission_name("content.studio.manage"), do: dgettext("access", "content.studio.manage")

  def permission_name("content.relation.manage"),
    do: dgettext("access", "content.relation.manage")

  def permission_name("content.homepage.pin"), do: dgettext("access", "content.homepage.pin")
  def permission_name("video.upload.view"), do: dgettext("access", "video.upload.view")
  def permission_name("video.upload.create"), do: dgettext("access", "video.upload.create")
  def permission_name("video.upload.delete"), do: dgettext("access", "video.upload.delete")
  def permission_name("video.upload.retry"), do: dgettext("access", "video.upload.retry")
  def permission_name("video.source.view"), do: dgettext("access", "video.source.view")
  def permission_name("video.source.create"), do: dgettext("access", "video.source.create")
  def permission_name("video.source.edit"), do: dgettext("access", "video.source.edit")
  def permission_name("video.source.delete"), do: dgettext("access", "video.source.delete")
  def permission_name("video.voiceover.manage"), do: dgettext("access", "video.voiceover.manage")
  def permission_name("video.subtitle.manage"), do: dgettext("access", "video.subtitle.manage")
  def permission_name("video.domain.manage"), do: dgettext("access", "video.domain.manage")
  def permission_name("video.player.manage"), do: dgettext("access", "video.player.manage")
  def permission_name("video.error.view"), do: dgettext("access", "video.error.view")
  def permission_name("video.error.resolve"), do: dgettext("access", "video.error.resolve")
  def permission_name("video.watch.play"), do: dgettext("access", "video.watch.play")
  def permission_name("video.settings.toggle"), do: dgettext("access", "video.settings.toggle")
  def permission_name("blog.post.view"), do: dgettext("access", "blog.post.view")
  def permission_name("blog.post.create"), do: dgettext("access", "blog.post.create")
  def permission_name("blog.post.edit"), do: dgettext("access", "blog.post.edit")
  def permission_name("blog.post.publish"), do: dgettext("access", "blog.post.publish")
  def permission_name("blog.post.pin"), do: dgettext("access", "blog.post.pin")
  def permission_name("blog.post.delete"), do: dgettext("access", "blog.post.delete")
  def permission_name("blog.tag.manage"), do: dgettext("access", "blog.tag.manage")
  def permission_name("blog.draft.view"), do: dgettext("access", "blog.draft.view")

  def permission_name("announcements.banner.manage"),
    do: dgettext("access", "announcements.banner.manage")

  def permission_name("announcements.global.manage"),
    do: dgettext("access", "announcements.global.manage")

  def permission_name("announcements.personal.send"),
    do: dgettext("access", "announcements.personal.send")

  def permission_name("announcements.notification.view"),
    do: dgettext("access", "announcements.notification.view")

  def permission_name("announcements.modal.manage"),
    do: dgettext("access", "announcements.modal.manage")

  def permission_name("feedback.ticket.view"), do: dgettext("access", "feedback.ticket.view")
  def permission_name("feedback.ticket.reply"), do: dgettext("access", "feedback.ticket.reply")
  def permission_name("feedback.ticket.assign"), do: dgettext("access", "feedback.ticket.assign")
  def permission_name("feedback.ticket.close"), do: dgettext("access", "feedback.ticket.close")

  def permission_name("feedback.template.manage"),
    do: dgettext("access", "feedback.template.manage")

  def permission_name("billing.transaction.view"),
    do: dgettext("access", "billing.transaction.view")

  def permission_name("billing.transaction.resolve"),
    do: dgettext("access", "billing.transaction.resolve")

  def permission_name("billing.donation.view"), do: dgettext("access", "billing.donation.view")
  def permission_name("billing.donation.edit"), do: dgettext("access", "billing.donation.edit")
  def permission_name("billing.donor.link"), do: dgettext("access", "billing.donor.link")
  def permission_name("billing.refund.create"), do: dgettext("access", "billing.refund.create")
  def permission_name("billing.stats.view"), do: dgettext("access", "billing.stats.view")
  def permission_name("audit.log.view"), do: dgettext("access", "audit.log.view")
  def permission_name("audit.log.export"), do: dgettext("access", "audit.log.export")
  def permission_name("settings.general.edit"), do: dgettext("access", "settings.general.edit")
  def permission_name("settings.seo.edit"), do: dgettext("access", "settings.seo.edit")
  def permission_name("settings.email.edit"), do: dgettext("access", "settings.email.edit")

  def permission_name("settings.registration.edit"),
    do: dgettext("access", "settings.registration.edit")

  def permission_name("settings.notifications.edit"),
    do: dgettext("access", "settings.notifications.edit")

  def permission_name("settings.security.edit"), do: dgettext("access", "settings.security.edit")
  def permission_name("system.queue.view"), do: dgettext("access", "system.queue.view")
  def permission_name("system.queue.manage"), do: dgettext("access", "system.queue.manage")
  def permission_name("system.cron.view"), do: dgettext("access", "system.cron.view")
  def permission_name("system.cron.manage"), do: dgettext("access", "system.cron.manage")
  def permission_name("system.cache.clear"), do: dgettext("access", "system.cache.clear")
  def permission_name("system.storage.view"), do: dgettext("access", "system.storage.view")
  def permission_name("system.storage.manage"), do: dgettext("access", "system.storage.manage")
  def permission_name("system.database.view"), do: dgettext("access", "system.database.view")
  def permission_name("system.log.view"), do: dgettext("access", "system.log.view")
  def permission_name(_), do: gettext("Неизвестное разрешение")

  # Search both locales without changing stored names, SQL ordering or pagination.
  def matching_permissions(q), do: matching(Catalog.codes(), q, &permission_name/1)

  def matching_system_roles(q),
    do: matching(~w(user comment_moderator content_editor admin owner), q, &system_role_name/1)

  defp matching(codes, q, label) do
    needle = String.downcase(q)

    Enum.filter(codes, fn code ->
      Enum.any?(["ru", "en"], fn locale ->
        Gettext.with_locale(AnimeWeb.Gettext, locale, fn ->
          String.contains?(String.downcase(label.(code)), needle)
        end)
      end)
    end)
  end
end
