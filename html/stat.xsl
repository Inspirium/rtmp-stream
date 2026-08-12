<?xml version="1.0" encoding="utf-8" ?>
<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
<xsl:output method="html" encoding="utf-8" doctype-system="about:legacy-compat" />

<xsl:template match="/rtmp">
<html>
<head>
<title>rtmp status</title>
<meta charset="utf-8"/>
<style>
  html { color-scheme: light dark; }
  body { font-family: -apple-system, Tahoma, Verdana, Arial, sans-serif; margin: 2em; }
  table { border-collapse: collapse; width: 100%; margin-bottom: 1.5em; }
  th, td { border: 1px solid rgba(127,127,127,.4); padding: .3em .6em; text-align: left; font-size: .9em; }
  th { background: rgba(127,127,127,.15); }
  h1 { font-size: 1.2em; }
  h2 { font-size: 1em; margin-top: 1.5em; }
  .muted { color: rgba(127,127,127,.9); font-size: .85em; }
</style>
</head>
<body>
  <h1>nginx-rtmp status</h1>
  <p class="muted">
    nginx <xsl:value-of select="nginx_version"/> /
    rtmp-module <xsl:value-of select="nginx_rtmp_version"/> /
    pid <xsl:value-of select="pid"/> /
    uptime <xsl:value-of select="uptime"/>s
  </p>
  <table>
    <tr><th>bw in</th><th>bytes in</th><th>bw out</th><th>bytes out</th><th>accepted</th></tr>
    <tr>
      <td><xsl:value-of select="bw_in"/></td>
      <td><xsl:value-of select="bytes_in"/></td>
      <td><xsl:value-of select="bw_out"/></td>
      <td><xsl:value-of select="bytes_out"/></td>
      <td><xsl:value-of select="naccepted"/></td>
    </tr>
  </table>

  <xsl:for-each select="server">
    <xsl:for-each select="application">
      <h2>application: <xsl:value-of select="name"/></h2>
      <table>
        <tr>
          <th>stream</th><th>clients</th><th>time (s)</th>
          <th>bw in</th><th>bytes in</th><th>bw out</th><th>bytes out</th>
          <th>publishing</th><th>active</th>
        </tr>
        <xsl:for-each select="live/stream">
          <tr>
            <td><xsl:value-of select="name"/></td>
            <td><xsl:value-of select="nclients"/></td>
            <td><xsl:value-of select="time"/></td>
            <td><xsl:value-of select="bw_in"/></td>
            <td><xsl:value-of select="bytes_in"/></td>
            <td><xsl:value-of select="bw_out"/></td>
            <td><xsl:value-of select="bytes_out"/></td>
            <td><xsl:if test="publishing">yes</xsl:if></td>
            <td><xsl:if test="active">yes</xsl:if></td>
          </tr>
        </xsl:for-each>
      </table>
    </xsl:for-each>
  </xsl:for-each>
</body>
</html>
</xsl:template>
</xsl:stylesheet>
