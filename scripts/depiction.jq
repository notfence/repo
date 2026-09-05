{
  minVersion: "0.4",
  class: "DepictionTabView",
  tintColor: "#1769e0",
  tabs: [
    {
      class: "DepictionStackView",
      tabname: "Details",
      views: [
        {
          class: "DepictionHeaderView",
          title: $name,
          useBoldText: true
        },
        {
          class: "DepictionMarkdownView",
          markdown: $description,
          useSpacing: true
        },
        {
          class: "DepictionTableTextView",
          title: "Version",
          text: $version
        },
        {
          class: "DepictionTableButtonView",
          title: "View on GitHub",
          action: $homepage,
          openExternal: true
        }
      ]
    },
    {
      class: "DepictionStackView",
      tabname: "Changelog",
      views: [
        $releases[] as $release |
        {
          class: "DepictionSubheaderView",
          title: $release.version,
          useBoldText: true
        },
        {
          class: "DepictionMarkdownView",
          markdown: $release.notes,
          useSpacing: true
        },
        {
          class: "DepictionSeparatorView"
        }
      ]
    }
  ]
}
