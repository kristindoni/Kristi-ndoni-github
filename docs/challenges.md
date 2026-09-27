# Problems I hit and how I fixed them

Everything below happened while building this against a real Azure
subscription. Just the problem and the fix, no long story.

| Problem | Fix |
|---|---|
| Subscription only allowed 4 vCPUs total in the region I picked first, so both tiers together never fit | Moved to a region with room and switched to a smaller VM size |
| Terraform tried to size a couple of resources using values it can't know until after apply | Used explicit true/false variables instead |
| Application Gateway rejected its internal IP and its TLS policy | Pinned a static IP and switched to the current supported TLS policy |
| The firewall blocked the app's own internal call to itself | Added the headers it was missing instead of loosening the firewall |
| Postgres requiring SSL broke the test pipeline, which uses a throwaway database that doesn't support it | Added a switch so SSL is on in production and off in tests |
| Postgres refused to be fully private even inside a private subnet, and zone redundant HA isn't offered on this subscription tier | Turned off public access explicitly, left HA off with one variable to flip it on elsewhere |
| Built container images on my own machine's chip type, which didn't match the servers | Built explicitly for the server's architecture instead |
| Fixing a config value didn't take effect on running instances | Had to recreate the instances, not just refresh them |
| A rolling update refused to start while instances were already unhealthy | Fixed the underlying health issue first, then the update ran fine |
| A crashed container just stayed down instead of retrying | Added a restart policy so it recovers on its own |
| Almost had the pipeline deploy to the wrong region because two variables weren't wired in | Caught it in a plan before it applied, added the missing variables |
| A couple of stale state locks, and some resources Terraform briefly lost track of | Cleared the locks by hand, re-imported the resources |
| Two pushes close together once caused a real lock collision | Made the pipeline queue runs instead of letting them race |
| Backup script's database tool was older than the database itself | Installed a newer version of the tool |
