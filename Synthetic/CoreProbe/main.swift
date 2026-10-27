// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import LauncherChecks
let results=CoreChecks().run()
let passed=results.allSatisfy{$0["status"]=="pass"}
let report:[String:Any] = ["pass":passed,"checks":results]
print(String(decoding:try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]),as:UTF8.self))
exit(passed ? 0:1)
