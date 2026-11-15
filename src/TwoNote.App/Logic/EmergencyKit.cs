using System.Globalization;
using System.Net;

namespace TwoNote.App.Logic;

/// <summary>
/// The Emergency Kit: one self-contained HTML file (no scripts, no external resources) that prints cleanly on
/// a single page. It holds everything needed to get back into the account except the password, for which it
/// leaves a line to write on.
/// </summary>
public static class EmergencyKit
{
    /// <summary>The file name suggested when saving.</summary>
    public static string SuggestedFileName(string username)
    {
        var safe = new string(username.Where(c => char.IsLetterOrDigit(c) || c is '-' or '_').Take(40).ToArray());
        return $"TwoNote Emergency Kit{(safe.Length > 0 ? " - " + safe : "")}.html";
    }

    /// <summary>Builds the document. The password is never passed in and never part of it.</summary>
    public static string BuildHtml(string serverUrl, string username, string secretKey, DateTimeOffset created)
    {
        static string E(string s) => WebUtility.HtmlEncode(s);
        var date = created.ToLocalTime().ToString("d MMMM yyyy", CultureInfo.InvariantCulture);
        return $$"""
            <!DOCTYPE html>
            <html lang="en">
            <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>TwoNote Emergency Kit</title>
            <style>
              @page { size: A4; margin: 18mm; }
              * { box-sizing: border-box; }
              body { font-family: "Segoe UI", system-ui, -apple-system, Helvetica, Arial, sans-serif; color: #1b1b1b; background: #fff;
                     max-width: 170mm; margin: 12mm auto; padding: 0 6mm; line-height: 1.45; font-size: 11pt; }
              h1 { font-size: 22pt; margin: 0 0 2mm; font-weight: 600; }
              .sub { color: #555; margin: 0 0 8mm; }
              .field { margin: 0 0 6mm; break-inside: avoid; }
              .label { font-size: 8.5pt; letter-spacing: .08em; text-transform: uppercase; color: #555; margin-bottom: 1.5mm; }
              .value { border: 1px solid #999; border-radius: 2mm; padding: 3.2mm 4mm; font-size: 13pt; min-height: 12mm; word-break: break-all; }
              .key { font-family: Consolas, "Cascadia Mono", "Courier New", monospace; font-size: 15pt; letter-spacing: .04em; font-weight: 600; }
              .blank { height: 14mm; }
              .warn { border-left: 1.2mm solid #b3261e; padding: 2mm 0 2mm 4mm; margin: 8mm 0; break-inside: avoid; }
              .warn strong { color: #b3261e; }
              ol { padding-left: 5mm; margin: 2mm 0; }
              .foot { color: #555; font-size: 9pt; margin-top: 8mm; border-top: 1px solid #ccc; padding-top: 3mm; }
              @media print { body { margin: 0 auto; padding: 0; } .noprint { display: none; } }
            </style>
            </head>
            <body>
            <h1>TwoNote Emergency Kit</h1>
            <p class="sub">Created {{E(date)}}. Print this page, write your password on it by hand, and keep it somewhere safe.</p>

            <div class="field"><div class="label">Server address</div><div class="value">{{E(serverUrl)}}</div></div>
            <div class="field"><div class="label">Username</div><div class="value">{{E(username)}}</div></div>
            <div class="field"><div class="label">Secret Key</div><div class="value key">{{E(secretKey)}}</div></div>
            <div class="field"><div class="label">Master password (write it here by hand)</div><div class="value blank"></div></div>

            <div class="warn">
              <strong>There is no recovery.</strong> Your notes are encrypted with your master password <em>and</em> this Secret Key.
              The server never sees either. If you lose the password, or lose every copy of the Secret Key, nobody
              &ndash; not even the person running the server &ndash; can decrypt your notes.
            </div>

            <div class="field">
              <div class="label">To set up a new device</div>
              <ol>
                <li>Install TwoNote and enter the server address above.</li>
                <li>Choose <b>Add this device</b>.</li>
                <li>Enter the username, your master password and the Secret Key.</li>
              </ol>
            </div>

            <p class="foot">Anyone who has this page <em>and</em> your password can read your notes. Do not store this file in a place
            other people can reach, and delete the file once it is printed if the computer is shared.
            <span class="noprint">To print: Ctrl+P.</span></p>
            </body>
            </html>

            """;
    }
}
