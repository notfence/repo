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
        {
          class: "DepictionHeaderView",
          title: $releaseTitle,
          useBoldText: true
        },
        {
          class: "DepictionTableTextView",
          title: "Published",
          text: $releaseDate
        },
        {
          class: "DepictionMarkdownView",
          markdown: $changelog,
          useSpacing: true
        }
      ]
    }
  ]
}
