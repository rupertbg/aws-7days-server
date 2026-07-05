# 7 Days to Die - Dedicated Server on AWS
Run a dedicated 7 Days to Die server that scales to zero when empty, with start/stop access control, idle shutdown when no players connected, self-healing, and a static IP address.

## Architecture
The architecture consists of three main components. A 100GB gp3 EBS Volume, an Elastic IP Address and an Auto Scaling Group. The ASG runs `MinSize 0 / MaxSize 1`: it holds zero instances when the server is idle (so there is no compute cost) and one instance when the server is up. Max is 1 by design - a 7DTD dedicated server is a single authoritative process owning one world save on one volume, so there is nothing to scale horizontally. The instance defaults to `r8i.xlarge` (4 vCPU / 32 GiB), memory-optimized for large V3.0 random-gen worlds; override the `InstanceType` parameter for smaller maps. The volume is deployed separately, so instances can be re-launched without deleting the volume, keeping any existing game data between instances. Each instance runs Ubuntu 24.04 LTS (The Fun Pimps' officially supported Linux target) and runs the server under systemd. The save volume is mounted at `/opt/games`, the server is installed at `/opt/games/7days`, and the game's user-data folder (worlds, saves, player profiles) is placed at `/opt/games/userdata` so all game state lives on the persistent volume.

Because the ASG launches instances from a launch template rather than managing one persistent instance, each launch re-runs the UserData bootstrap: it self-attaches the save volume, self-associates the Elastic IP, and rewrites `serverconfig.xml`. This makes the template the source of truth (no config drift), but it also means the ASG does not attach the volume or IP for you - the instance does that itself on boot. A stack update that changes the launch template applies on the *next* launch; it does not roll a running server.
![Deployment Architecture](7days.png)

## Configuration
The main 7 Days to Die server configuration is a `serverconfig.xml` written to `/opt/games/7days/serverconfig.xml` by the instance's UserData script (defined inline in `instance.yml`).

As of 7 Days to Die V3.0, gameplay settings (difficulty, zombie speed, loot, blood moon, drop-on-death, day length, air drops, etc.) are no longer individual properties. They are all encoded in a single `SandboxCode` string, exposed here as the `SandboxCode` CloudFormation parameter. Generate your own from the in-game Sandbox Options menu; the default is the standard Adventurer preset.

## Deployment
There are three main CloudFormation templates. The EIP and EBS Volume templates can be run in any order. The instance/ASG template must be run after both of the other templates have been deployed.
  1. Deploy `ip.yml`
  2. Deploy `volume.yml`
  3. Ensure you have the following SSM Parameters:
    - 7days-password: Password for the server itself
    - 7days-server-ip-bucket: An S3 bucket name to upload `7dserver.txt`, containing server IP and port in `0.0.0.0:26900` format.
  4. Deploy `instance.yml`, passing a `SubnetId` in the same Availability Zone as the volume and EIP (`${AWS::Region}a`).

The dedicated server (Steam app 294420) is downloaded with an anonymous Steam login, so no Steam credentials are required.

The ASG is created at desired capacity 0 (no instance running), so nothing costs compute until you start the server on demand (see below).

### Region and Availability Zone
Deploy all three stacks in the same region. The default target is `ap-southeast-6` (New Zealand), which is what `7days.bat` is set to; the instance-type default (`r8i.xlarge`) is chosen for what that region offers. If you deploy elsewhere, pick an `InstanceType` available there (note: 7 Days to Die has no ARM64 server build, so Graviton instances such as `r8g`/`m8g` will not work).

`volume.yml` pins the Availability Zone to `${AWS::Region}a`, and the ASG must launch into that same AZ because a single EBS volume attaches to one instance in one AZ. Pass `instance.yml` a `SubnetId` that lives in the `-a` AZ. Confirm your chosen instance type is offered there; if not, change the `a` suffix in `volume.yml` (and pick a subnet in the matching AZ) to a supporting AZ.

## Usage
Check the S3 bucket (`s3://${S3BucketName}/7dserver.txt`) for the IP and port of the server. Because the address is a static Elastic IP, it stays the same across every launch. Then connect to it using 7 Days to Die. The default game port is UDP/TCP 26900.

### Start/Stop Access Control
If you make an IAM User for people who want to be able to turn on the server on-demand then you can provide them `7days.bat` to enable them to easily turn on and off the server, without them knowing any instance or ASG detail. Starting sets the ASG desired capacity to 1; stopping sets it to 0.

Pass in the action (either start or stop). You can optionally provide an AWS CLI profile name to use instead of the default e.g. `7days.bat start myprofile`

If you would like to lock down the IAM User to only be able to control this 7 Days server then attach this policy to the user:
```json
{
  "Version": "2012-10-17",
  "Statement": [{
      "Action": [
        "autoscaling:SetDesiredCapacity"
      ],
      "Condition": {
        "StringEquals": {
          "autoscaling:ResourceTag/AccessControl": "7Days"
        }
      },
      "Resource": "*",
      "Effect": "Allow"
    },
    {
      "Effect": "Allow",
      "Action": "autoscaling:DescribeAutoScalingGroups",
      "Resource": "*"
    }
  ]
}
```

### Idle Shutdown
A systemd timer (`7dtd-idle.timer`) runs `/usr/local/bin/7dtd-idle-check` every 20 minutes. It uses an automated telnet connection (`/usr/local/bin/7dtd-listplayers`) to read how many players are currently connected. If it positively reads zero players it terminates the instance and decrements the ASG's desired capacity to 0, so the group stays empty (a plain OS shutdown would just be relaunched). If the server or its telnet console is unreachable it does nothing, so the server is never scaled down before it has started.

### Self-healing
Two layers keep the server up. The ASG's `EC2` health check replaces an instance whose host fails its status checks (a dead or hung host). On top of that, a systemd timer (`7dtd-health.timer`) runs `/usr/local/bin/7dtd-health-check` every 5 minutes: if the game console was reachable earlier this boot but then stops responding for three consecutive checks, it marks the instance `Unhealthy` so the ASG replaces the wedged process. It never acts until the server has been healthy at least once (state lives on tmpfs and resets each boot), so a slow first boot or world-gen is never killed.

