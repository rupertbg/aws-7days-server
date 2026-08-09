@echo off
setlocal
set action=%1
set profile=%2

rem Region and the AccessControl tag are configurable without editing this file:
rem   set SEVENDAYS_REGION=ap-southeast-2
rem   set SEVENDAYS_TAG=7Days
rem Leaving SEVENDAYS_REGION unset uses whatever region the AWS CLI resolves
rem from the profile or environment. SEVENDAYS_TAG must match the
rem AccessControlTagValue parameter the instance stack was deployed with.
if "%SEVENDAYS_TAG%" == "" set SEVENDAYS_TAG=7Days
set regionarg=
if not "%SEVENDAYS_REGION%" == "" set regionarg=--region %SEVENDAYS_REGION%

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
  FOR /F "tokens=* USEBACKQ" %%F IN (`aws --profile %profile% %regionarg% autoscaling describe-auto-scaling-groups --filters "Name=tag:AccessControl,Values=%SEVENDAYS_TAG%" --query AutoScalingGroups[0].AutoScalingGroupName --output text`) DO (set asg=%%F)
  if "%asg%" == "" goto NoAsg
  if "%asg%" == "None" goto NoAsg
  aws --profile %profile% %regionarg% autoscaling set-desired-capacity --auto-scaling-group-name %asg% --desired-capacity %desired% --output text
  echo | set /p="Set %asg% desired capacity to %desired%"
  goto:EOF

:NoAsg
  echo | set /p="No 7Days Auto Scaling Group found"
  goto:EOF
