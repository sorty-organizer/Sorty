#!/bin/bash

render_appcast() {
    local output_file="$1"
    local channel_xml=""
    local minimum_system_xml=""

    if [ -n "${APPCAST_CHANNEL:-}" ]; then
        channel_xml="      <sparkle:channel>${APPCAST_CHANNEL}</sparkle:channel>"
    fi
    if [ -n "${MINIMUM_SYSTEM_VERSION:-}" ]; then
        minimum_system_xml="      <sparkle:minimumSystemVersion>${MINIMUM_SYSTEM_VERSION}</sparkle:minimumSystemVersion>"
    fi

    cat > "${output_file}" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>${PROJECT_NAME} Changelog</title>
    <link>${APPCAST_LINK}</link>
    <description>Most recent changes with links to updates.</description>
    <language>en</language>
    <item>
      <title>${APPCAST_ITEM_TITLE}</title>
${channel_xml}
      <sparkle:releaseNotesLink>${RELEASE_NOTES_URL}</sparkle:releaseNotesLink>
${minimum_system_xml}
      <pubDate>${DATE}</pubDate>
      <enclosure url="${RELEASE_URL}"
                 sparkle:version="${BUILD_NUM}"
                 sparkle:shortVersionString="${VERSION}"
                 type="application/octet-stream"
                 ${ENCLOSURE_EXTRA_ATTR}/>
${APPCAST_DELTAS_XML:-}
    </item>
  </channel>
</rss>
EOF
}
