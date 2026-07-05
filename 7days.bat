@echo off
setlocal
set region="ap-southeast-6"
set action=%1
set profile=%2

if "%profile%" == "" set profile="default"

if "%action%" == "start" set desired=1
if "%action%" == "stop" set desired=0
if not defined desired goto Help
goto Run

:Help
  echo | set /p="You must pass in the action (either start or stop). You can optionally provide an AWS CLI profile name to use"
  echo | set /p="Usage: 7days.bat start^|stop [awsprofile]"
  goto:EOF

:Run
  FOR /F "tokens=* USEBACKQ" %%F IN (`aws --profile %profile% --region %region% autoscaling describe-auto-scaling-groups --filters "Name=tag:AccessControl,Values=7Days" --query AutoScalingGroups[0].AutoScalingGroupName --output text`) DO (set asg=%%F)
  if "%asg%" == "" goto NoAsg
  if "%asg%" == "None" goto NoAsg
  aws --profile %profile% --region %region% autoscaling set-desired-capacity --auto-scaling-group-name %asg% --desired-capacity %desired% --output text
  echo | set /p="Set %asg% desired capacity to %desired%"
  goto:EOF

:NoAsg
  echo | set /p="No 7Days Auto Scaling Group found"
  goto:EOF
