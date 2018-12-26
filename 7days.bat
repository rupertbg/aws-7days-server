@echo off
set region="ap-southeast-1"
set action=%1
set profile=%2

if "%profile%" == "" set profile="default"

if "%action%" == "start" goto Run
if "%action%" == "stop" goto Run

:Help
  echo | set /p="You must pass in the action (either start or stop). You can optionally provide an AWS CLI profile name to use"
  echo | set /p="Usage: 7days.bat start|stop [awsprofile]"
  goto:EOF

:Run
  if "%action%" == "start" set state="stopped"
  if "%action%" == "stop" set state="running"
  FOR /F "tokens=* USEBACKQ" %%F IN (`aws --profile %profile% --region %region% ec2 describe-instances --filters "Name=tag:Name,Values=7DaysServer" "Name=instance-state-name,Values=%state%" --query Reservations[0].Instances[0].InstanceId --output text`) DO (set instance=%%F)
  if not "%instance:~0,2%" == "i-" goto NoInstance
  aws --profile %profile% --region %region% ec2 %action%-instances --instance-ids %instance% --output text
  goto:EOF

:NoInstance
  echo | set /p="No instance found to %action%"
  goto:EOF
