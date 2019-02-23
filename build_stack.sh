#!/bin/bash
##########################################
# script to build and tear down
# a cloudformation stack
# If any stack exists, deletes it and exits
# else creates a new one
##########################################

# Fail on any error
set -e

vExistingStacks=$(aws cloudformation list-stacks --stack-status-filter CREATE_COMPLETE ROLLBACK_COMPLETE --query StackSummaries[*].StackName --output text)
for stack in ${vExistingStacks} ; do
	echo "Deleting Existing Stack: ${stack}"
	aws cloudformation delete-stack --stack-name ${stack}
	aws cloudformation wait stack-delete-complete --stack-name ${stack}
done
if [[ ! -z ${vExistingStacks} ]] ; then
	echo "Existing stacks deleted. Rerun to create new"
	exit 0
fi

vKeyFile="./admin_key_pair.pem"
vStackName="ns-ec2-instances"
vCftFile="file://cft-ec2-instances.json"
vIp=$(curl http://checkip.amazonaws.com 2> /dev/null)
vDefaultVpcId=$(aws ec2 describe-vpcs --filter "Name=isDefault,Values=true" --query Vpcs[0].VpcId --output text)

echo "IP address for this box: ${vIp}"
echo "Default VPC Id: ${vDefaultVpcId}"

if [[ ! -f ${vKeyFile} ]] ; then
	echo "Key file ${vKeyFile} NOT found!"
	exit 1
fi

echo "Building Stack"
aws cloudformation create-stack --stack-name ${vStackName} --template-body ${vCftFile} --parameters  ParameterKey=VPCIdParameter,ParameterValue=${vDefaultVpcId} ParameterKey=InboundAllowedCIDRParameter,ParameterValue=${vIp}/32
echo "waiting for the stack build to complete..."
aws cloudformation wait stack-create-complete --stack-name ${vStackName}

vInstanceIds=$(aws ec2 describe-instances --filter "Name=instance-state-name,Values=running" --query Reservations[*].Instances[*].InstanceId --output text)
vInstance1=$(echo $vInstanceIds | awk '{ print $1}')
vInstance2=$(echo $vInstanceIds | awk '{ print $2}')

vPublicDnsNames=$(aws ec2 describe-instances --filter "Name=instance-state-name,Values=running" --query Reservations[*].Instances[*].PublicDnsName --output text)
vBox1=$(echo $vPublicDnsNames | awk '{ print $1}')
vBox2=$(echo $vPublicDnsNames | awk '{ print $2}')

echo "Configuring HTTP Server on ${vInstance1}, ${vBox1}"
ssh -i ${vKeyFile} ec2-user@${vBox1} -o "StrictHostKeyChecking no" << EOF
  sudo yum update -y
  sudo yum install -y httpd
  sudo service httpd start
  sudo chkconfig httpd on
  cd /var/www/html
  sudo su
  echo "This is the Main Website" > index.html
EOF

echo "Configuring HTTP Server on ${vInstance2}, ${vBox2}"
ssh -i ${vKeyFile} ec2-user@${vBox2} -o "StrictHostKeyChecking no" << EOF
  sudo yum update -y
  sudo yum install -y httpd
  sudo service httpd start
  sudo chkconfig httpd on
  cd /var/www/html
  sudo su
  echo "This is the Secondary Website" > index.html
EOF

