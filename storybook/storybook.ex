defmodule ApiaryWeb.Storybook do
  @moduledoc """
  The component storybook, a development tool (`docs/ui.md`, Storybook): the stories under
  `storybook/` (`*.story.exs`), drawn with the app's own components and stylesheet, served
  at `/dev/storybook` where `:dev_routes` is set (`ApiaryWeb.Routes.storybook_routes/0`).

  Compiled in dev and test only, beside its dependency, `phoenix_storybook`; a release has
  neither. The stylesheet is the app's with the stories' classes besides
  (`assets/css/storybook.css`, built by the `storybook` Tailwind profile of
  `config/dev.exs`), so a story looks as the page does. The header's theme menu draws the
  stories in `qory` or `qory-dark`, set as `data-theme` on each story's container, as the
  app sets it on the page.

  In test every story is compiled with this module, and `ApiaryWeb.StorybookTest` renders
  every variation of each, so a story that no longer renders fails the suite.
  """
  use PhoenixStorybook,
    otp_app: :apiary,
    title: "Qory Apiary storybook",
    content_path: Path.expand(".", __DIR__),
    css_path: "/assets/css/storybook.css",
    themes: [qory: [name: "Light (qory)"], "qory-dark": [name: "Dark (qory-dark)"]],
    themes_strategies: [data_attribute: "theme"]
end
