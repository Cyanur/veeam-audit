<div align="center">

# Veeam Audit Scripts

<p>
  <strong>PowerShell tooling for auditing and documenting Veeam environments</strong>
</p>
<p>
  <strong>[FR] only atm, [EN] in dev</strong>
</p>
<p>
  <img src="https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell&logoColor=white" alt="PowerShell">
  <img src="https://img.shields.io/badge/Veeam-VBR%2012%20%7C%2013-00AEEF?logo=veeam&logoColor=white" alt="Veeam Backup & Replication">
  <img src="https://img.shields.io/badge/Veeam-VB365-00AEEF?logo=veeam&logoColor=white" alt="Veeam Backup for Microsoft 365">
  <img src="https://img.shields.io/badge/Platform-Windows-0078D4?logo=windows&logoColor=white" alt="Windows">
</p>

<p>
  <em>Automated auditing, configuration reporting and documentation for Veeam environments.</em>
</p>

</div>

<hr>

<h2>📋 Overview</h2>

<p>
  <strong>Veeam Audit Scripts</strong> is a collection of PowerShell scripts designed to
  <strong>audit, document and assess Veeam environments</strong>.
</p>

<p>
  The project aims to provide infrastructure administrators, engineers and consultants
  with a quick and structured overview of a Veeam environment without having to manually
  browse through the entire Veeam console.
</p>

<p>
  The scripts collect configuration information and generate structured
  <strong>CSV reports</strong> and, depending on the script, a consolidated
  <strong>HTML report</strong>.
</p>

<hr>

<h2>🎯 Objectives</h2>

<table>
<tr>
<td width="33%" align="center">
<h3>🔎 Audit</h3>
<p>Quickly identify the configuration and components of a Veeam environment.</p>
</td>

<td width="33%" align="center">
<h3>📊 Document</h3>
<p>Generate structured reports that can be archived and shared.</p>
</td>

<td width="33%" align="center">
<h3>⚠️ Assess</h3>
<p>Identify configuration points requiring additional investigation.</p>
</td>
</tr>
</table>

<hr>

<h2>🚀 Supported Products</h2>

<table>
<thead>
<tr>
<th>Product</th>
<th>Scope</th>
<th>Versions</th>
</tr>
</thead>
<tbody>
<tr>
<td><strong>Veeam Backup & Replication</strong></td>
<td>Infrastructure, jobs, repositories, proxies, tapes, GFS, configuration</td>
<td>12.x / 12.3.x / 13.x</td>
</tr>
<tr>
<td><strong>Veeam Backup for Microsoft 365</strong></td>
<td>Infrastructure, repositories, proxies, jobs, organizations and M365 objects</td>
<td>8.X</td>
</tr>
</tbody>
</table>

<hr>

<h2>🖥️ Veeam Backup & Replication</h2>

<p>
The VBR audit collects information from the main components of the
<strong>Veeam Backup & Replication</strong> infrastructure.
</p>

<table>
<thead>
<tr>
<th>Category</th>
<th>Collected information</th>
</tr>
</thead>
<tbody>

<tr>
<td>🖥️ Infrastructure</td>
<td>
Veeam server, version, components and infrastructure information
</td>
</tr>

<tr>
<td>📦 Repositories</td>
<td>
Backup repositories, capacity information, configuration and storage details
</td>
</tr>

<tr>
<td>🗄️ SOBR</td>
<td>
Scale-Out Backup Repositories, extents and configuration
</td>
</tr>

<tr>
<td>🔌 Proxies</td>
<td>
Proxy servers, configuration and operational information
</td>
</tr>

<tr>
<td>💾 Backup Jobs</td>
<td>
Jobs, configuration, schedule, retention and execution information
</td>
</tr>

<tr>
<td>📅 GFS</td>
<td>
Weekly, monthly and yearly retention configuration
</td>
</tr>

<tr>
<td>📼 Tape</td>
<td>
Media pools, tape libraries and tape configuration
</td>
</tr>

<tr>
<td>⚙️ Services</td>
<td>
Veeam services, state and startup configuration
</td>
</tr>

<tr>
<td>🗃️ Database</td>
<td>
Database type and configuration information
</td>
</tr>

<tr>
<td>⚠️ Health checks</td>
<td>
Potential configuration points of attention
</td>
</tr>

</tbody>
</table>

<hr>

<h2>☁️ Veeam Backup for Microsoft 365</h2>

<p>
The VB365 audit provides a structured view of the Microsoft 365 backup environment.
</p>

<table>
<thead>
<tr>
<th>Category</th>
<th>Collected information</th>
</tr>
</thead>
<tbody>

<tr>
<td>🖥️ Infrastructure</td>
<td>
Server name, operating system and Veeam Backup for Microsoft 365 version
</td>
</tr>

<tr>
<td>🔑 Licensing</td>
<td>
License information, expiration and usage
</td>
</tr>

<tr>
<td>🗃️ Database</td>
<td>
Database type and configuration
</td>
</tr>

<tr>
<td>🔌 Proxies</td>
<td>
Proxy configuration, status, type and operating system
</td>
</tr>

<tr>
<td>⚙️ Services</td>
<td>
Veeam services, state, startup type and service account
</td>
</tr>

<tr>
<td>📦 Repositories</td>
<td>
Repository configuration, proxy association, path, retention, encryption and immutability
</td>
</tr>

<tr>
<td>💾 Backup Jobs</td>
<td>
Jobs, type, state, schedule, repository and protected objects
</td>
</tr>

<tr>
<td>🏢 Organizations</td>
<td>
Microsoft 365 organizations configured in VB365
</td>
</tr>

<tr>
<td>📧 Exchange Online</td>
<td>
Protected Exchange objects
</td>
</tr>

<tr>
<td>☁️ OneDrive</td>
<td>
Protected OneDrive objects
</td>
</tr>

<tr>
<td>📁 SharePoint</td>
<td>
Protected SharePoint sites
</td>
</tr>

<tr>
<td>💬 Teams</td>
<td>
Protected Microsoft Teams objects
</td>
</tr>

<tr>
<td>👥 Groups</td>
<td>
Microsoft 365 Groups and Security Groups
</td>
</tr>

</tbody>
</table>

<hr>

<h2>📊 Reports</h2>

<h3>CSV Export</h3>

<p>
The scripts generate individual CSV files for each audit category.
This makes the collected information easy to process and reuse.
</p>

<table>
<thead>
<tr>
<th>Advantage</th>
<th>Description</th>
</tr>
</thead>
<tbody>
<tr>
<td>📈 Excel</td>
<td>Open and analyze the results directly in Excel</td>
</tr>
<tr>
<td>⚙️ PowerShell</td>
<td>Reuse the exported data in other automation scripts</td>
</tr>
<tr>
<td>🔄 Comparison</td>
<td>Compare audits between different dates or environments</td>
</tr>
<tr>
<td>📚 Documentation</td>
<td>Keep an historical snapshot of the infrastructure</td>
</tr>
</tbody>
</table>

<h3>🌐 HTML Report</h3>

<p>
The HTML report provides a consolidated <strong>one-page view</strong>
of the Veeam environment.
</p>

<p>
The report is designed to make important information immediately visible,
including infrastructure components, jobs, repositories and potential
points of attention.
</p>

<hr>

<h2>⚠️ Audit & Health Checks</h2>

<p>
The scripts attempt to identify configuration elements that may require
additional investigation.
</p>

<table>
<thead>
<tr>
<th>Check</th>
<th>Example</th>
</tr>
</thead>
<tbody>
<tr>
<td>💾 Jobs</td>
<td>Disabled jobs or jobs without an expected schedule</td>
</tr>
<tr>
<td>📦 Storage</td>
<td>Repositories with low available capacity</td>
</tr>
<tr>
<td>♻️ Retention</td>
<td>Unexpected or inconsistent retention configuration</td>
</tr>
<tr>
<td>📅 GFS</td>
<td>Weekly / Monthly / Yearly configuration</td>
</tr>
<tr>
<td>⚙️ Services</td>
<td>Stopped or incorrectly configured Veeam services</td>
</tr>
<tr>
<td>🔑 Licensing</td>
<td>License expiration or usage requiring attention</td>
</tr>
<tr>
<td>🔒 Immutability</td>
<td>Repository immutability configuration</td>
</tr>
<tr>
<td>🧩 Infrastructure</td>
<td>Missing or inconsistent components</td>
</tr>
</tbody>
</table>

<blockquote>
<strong>⚠️ Important:</strong>
Detected points of attention are indicators and should not automatically
be considered errors. Critical findings should always be validated directly
against the Veeam console and the actual infrastructure.
</blockquote>

<hr>

<h2>▶️ Usage</h2>

<h3>Veeam Backup & Replication</h3>

<pre><code>.\Audit-VBR.ps1</code></pre>

<h3>Veeam Backup for Microsoft 365</h3>

<pre><code>.\Audit-VB365.ps1</code></pre>

<p>
Run the scripts from a PowerShell session with sufficient permissions to
query the Veeam configuration.
</p>

<hr>

<h2>📁 Repository Structure</h2>

<pre><code>.
├── VBR/
│   ├── Audit-VBR.ps1
│   └── README.md
│
├── VB365/
│   ├── Audit-VB365.ps1
│   └── README.md
│
├── Output/
│   ├── CSV/
│   └── HTML/
│
└── README.md
</code></pre>

<hr>

<h2>⚙️ Requirements</h2>

<table>
<thead>
<tr>
<th>Requirement</th>
<th>VBR</th>
<th>VB365</th>
</tr>
</thead>
<tbody>
<tr>
<td>Windows Server</td>
<td>✅</td>
<td>✅</td>
</tr>
<tr>
<td>PowerShell 5.1+</td>
<td>✅</td>
<td>✅</td>
</tr>
<tr>
<td>Veeam product installed</td>
<td>✅</td>
<td>✅</td>
</tr>
<tr>
<td>Veeam PowerShell interface</td>
<td>✅</td>
<td>✅</td>
</tr>
<tr>
<td>Read access to configuration</td>
<td>✅</td>
<td>✅</td>
</tr>
</tbody>
</table>

<hr>

<h2>🔄 Compatibility</h2>

<table>
<thead>
<tr>
<th>Product</th>
<th>Version</th>
<th>Status</th>
</tr>
</thead>
<tbody>
<tr>
<td rowspan="3"><strong>Veeam Backup & Replication</strong></td>
<td>12.x</td>
<td>🟢 Supported</td>
</tr>
<tr>
<td>12.3.x</td>
<td>🟢 Supported</td>
</tr>
<tr>
<td>13.x</td>
<td>🟢 Supported</td>
</tr>
<tr>
<td><strong>Veeam Backup for Microsoft 365</strong></td>
<td>Supported versions</td>
<td>🟢 Supported</td>
</tr>
</tbody>
</table>

<p>
Because Veeam PowerShell objects and properties may change between releases,
some features may behave differently depending on the installed version.
</p>

<hr>

<h2>🛡️ Security</h2>

<p>
The scripts are designed to perform <strong>read-only configuration collection</strong>.
They do not intentionally modify the Veeam environment.
</p>

<ul>
<li>❌ No modification of backup jobs</li>
<li>❌ No modification of repositories</li>
<li>❌ No modification of retention policies</li>
<li>❌ No deletion of backup data</li>
<li>❌ No start / stop operation of backup jobs</li>
<li>❌ No configuration changes</li>
</ul>

<h3>🔐 Sensitive information</h3>

<p>
Generated reports may contain sensitive infrastructure information such as:
</p>

<ul>
<li>Server names</li>
<li>Repository names</li>
<li>Storage paths</li>
<li>Job names</li>
<li>Microsoft 365 organization names</li>
<li>Service accounts</li>
<li>Infrastructure details</li>
</ul>

<blockquote>
<strong>⚠️ Never publish generated audit reports to a public repository
without reviewing and anonymizing sensitive information.</strong>
</blockquote>

<hr>

<h2>💡 Project Philosophy</h2>

<p>
The project was built around a simple question:
</p>

<blockquote>
<strong>
"If I take over a Veeam environment I don't know,
what information do I need to quickly understand its configuration?"
</strong>
</blockquote>

<p>
The scripts therefore focus on:
</p>

<table>
<tr>
<td align="center">🤖<br><strong>Automation</strong></td>
<td align="center">📖<br><strong>Readability</strong></td>
<td align="center">🔄<br><strong>Reproducibility</strong></td>
<td align="center">🧩<br><strong>Compatibility</strong></td>
</tr>
<tr>
<td align="center">📊<br><strong>Structured data</strong></td>
<td align="center">🔎<br><strong>Assessment</strong></td>
<td align="center">⚠️<br><strong>Health checks</strong></td>
<td align="center">📚<br><strong>Documentation</strong></td>
</tr>
</table>

<p>
The objective is to provide a practical toolkit for
<strong>Veeam administrators, infrastructure engineers and consultants</strong>.
</p>

<hr>

<h2>🗺️ Roadmap</h2>

<ul>
<li>⬜ Extended Veeam version compatibility</li>
<li>⬜ Additional configuration checks</li>
<li>⬜ More automated health checks</li>
<li>⬜ Audit comparison between two environments</li>
<li>⬜ Enhanced HTML reporting</li>
<li>⬜ JSON export</li>
<li>⬜ Excel export</li>
<li>⬜ Multi-server audit mode</li>
<li>⬜ Audit history</li>
<li>⬜ Extended VB365 configuration analysis</li>
</ul>

<hr>

<h2>⚠️ Disclaimer</h2>

<p>
<strong>Veeam Audit Scripts is not an official Veeam product.</strong>
</p>

<p>
The scripts use PowerShell interfaces and objects exposed by Veeam products
to collect configuration information.
</p>

<p>
The generated reports are intended as an <strong>audit and documentation aid</strong>
and do not replace Veeam's official monitoring, configuration or diagnostic tools.
</p>

<p>
Use at your own risk and validate critical findings against the actual
Veeam environment.
</p>

<hr>

<h2>🤝 Contributing</h2>

<p>
Contributions, bug reports and improvements are welcome.
</p>

<p>
When reporting an issue, please provide:
</p>

<ul>
<li>Veeam product and version</li>
<li>Windows Server version</li>
<li>PowerShell version</li>
<li>Full error message</li>
<li>Affected script or function</li>
<li>Relevant PowerShell output</li>
</ul>

<p>
Please remove or anonymize sensitive infrastructure information before
publishing it.
</p>

<hr>

<h2>📜 License</h2>

<p>
License to be defined.
</p>

<hr>

<div align="center">

<h3>Veeam Audit Scripts</h3>

<p>
<em>PowerShell tooling for Veeam infrastructure assessment and documentation.</em>
</p>

</div>
