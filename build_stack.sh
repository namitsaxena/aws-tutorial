#!/bin/bash
##########################################
# script to build and tear down
# a cloudformation stack
# If any stack exists, deletes it and exits
# else creates a new one
##########################################
set -e # Fail on any error, from this point onwards (fails on grep above if not found)

function deleteStack()
{
  stackName="$1"
  #check if the stack is active
  vExistingStacks=$(aws cloudformation list-stacks --stack-status-filter CREATE_COMPLETE ROLLBACK_COMPLETE --query StackSummaries[*].StackName --output text)
  for stack in ${vExistingStacks} ; do
    if [[ "${stack}" == "${stackName}" ]] ; then
      echo "Deleting Existing Stack: ${stack}"
      aws cloudformation delete-stack --stack-name ${stack}
      aws cloudformation wait stack-delete-complete --stack-name ${stack}
    fi  
  done
}

function checkS3Access()
{
  # checks if S3 is accessible from an instance
  # i.e. verifies if instance got applied with the S3 role
  typeset vHostname=$1
  typeset vKeyFilePath=$2
  vS3Output=$(ssh -o "StrictHostKeyChecking no" -i ${vKeyFilePath} ec2-user@${vHostname} "aws s3 ls"  2> /dev/null || echo "") # ORing since failure is expected
  if [[ "${vS3Output}" == "" ]] ; then
    echo "${vHostname} can NOT access S3"
    return 1
  else
    echo "${vHostname} can access s3 buckets:- ${vS3Output}"  
    return 0
  fi
}

function configureHTTPServer()
{
  typeset vHost=$1
  typeset vKeyFilePath=$2
  typeset vWebText=$3

  ssh -i ${vKeyFilePath} ec2-user@${vHost} -o "StrictHostKeyChecking no" << EOF
    sudo yum update -y
    sudo yum install -y httpd
    sudo service httpd start
    sudo chkconfig httpd on
    cd /var/www/html
    sudo su
    echo "${vWebText}" > index.html
EOF

}

vCommand="$1"

vCFTBucketName="ns-cft-bucket"
vStackName="ns-ec2-instances"
deleteStack ${vStackName}

if [[ "${vCommand}" == "DELETE" ]] ; then
  echo "Complete. Delete only option specified."
  exit 0
fi


vKeyFile="./admin_key_pair.pem"
vCftFile="file://cft-ec2-instances.json"
vIp=$(curl http://checkip.amazonaws.com 2> /dev/null)
vDefaultVpcId=$(aws ec2 describe-vpcs --filter "Name=isDefault,Values=true" --query Vpcs[0].VpcId --output text)

echo "IP address for this box: ${vIp}"
echo "Default VPC Id: ${vDefaultVpcId}"

if [[ ! -f ${vKeyFile} ]] ; then
	echo "Key file ${vKeyFile} NOT found!"
	exit 1
fi

echo "Copying CFT resources to s3..."
aws s3 cp cft-iam-role-ec2-s3-read-only.json s3://${vCFTBucketName}
echo "Building Stack..."
aws cloudformation create-stack --stack-name ${vStackName} --template-body ${vCftFile} --parameters  ParameterKey=VPCIdParameter,ParameterValue=${vDefaultVpcId} ParameterKey=InboundAllowedCIDRParameter,ParameterValue=${vIp}/32 --capabilities CAPABILITY_AUTO_EXPAND --capabilities CAPABILITY_NAMED_IAM

echo "waiting for the stack build to complete..."
aws cloudformation wait stack-create-complete --stack-name ${vStackName}

# filter only the instances used by ELB ; tagged as ELB in CFT
vInstanceIds=$(aws ec2 describe-instances --filter "Name=tag:used_by,Values=ELB" "Name=instance-state-name,Values=running" --query Reservations[*].Instances[*].InstanceId --output text)
vInstance1=$(echo $vInstanceIds | awk '{ print $1}')
vInstance2=$(echo $vInstanceIds | awk '{ print $2}')

vPublicDnsNames=$(aws ec2 describe-instances --filter "Name=tag:used_by,Values=ELB" "Name=instance-state-name,Values=running" --query Reservations[*].Instances[*].PublicDnsName --output text)
vBox1=$(echo $vPublicDnsNames | awk '{ print $1}')
vBox2=$(echo $vPublicDnsNames | awk '{ print $2}')

# double check if wrong instance(already configured) showed up by any chance
vBoxText1=$(curl ${vBox1} 2> /dev/null || true)
if [[ ! -z "${vBoxText1}" ]] ; then
  echo "Box 1 (${vInstance1} -- ${vBox1}) already configured (Text:  ${vBoxText1}). Incorrect Box Received. Swapping Box configuration..." >&2
  vBoxTemp=${vBox1}
  vBox1=${vBox2}
  vBox2=${vBoxTemp}
fi  
    
echo "Configuring HTTP Server on ${vInstance1}, ${vBox1}"
configureHTTPServer "${vBox1}" "${vKeyFile}" "This is the Main Website"

echo "HTTP Server on ${vInstance2}, ${vBox2} already configured using user-data script defined within cloud-formation"

sleep 10 # wait for instances to be up so that they can respond to below commands
# check 
vBoxText1=$(curl ${vBox1} 2> /dev/null)
echo "${vBox1} --> ${vBoxText1}"

vBoxText2=$(curl ${vBox2} 2> /dev/null)
echo "${vBox2} --> ${vBoxText2}"

# Since we created a new ASG (asg2, only 1 expected with tag ELB3) and made it join our original ELB, we need to check if that's being served as well
vPublicDnsNamesASG2Box=$(aws ec2 describe-instances --filter "Name=tag:used_by,Values=ELB3" "Name=instance-state-name,Values=running" --query Reservations[*].Instances[*].PublicDnsName --output text)
vBoxText3=$(curl ${vPublicDnsNamesASG2Box} 2> /dev/null)
echo "${vPublicDnsNamesASG2Box} --> ${vBoxText3}"

# The ELB used to work instantly (fluctuating between the two hosts) before CPU alarm was added.
# After the alarm it takes a while to fluctuate and work how it would be expected 
# (it may show only one website, typically seoond one without the alarm, constantly for the first several seconds)
# get the first loadbalancers public DNS name (assumes only one load balanacer is running)
# Update - because of ASG added later, it will also show up now (as unexpected)
# So far the order seems, Secondary(fastest), ASG, primary(take a while)
vLoadBalancerDNSName=$(aws elbv2 describe-load-balancers --query LoadBalancers[0].DNSName --output text)
echo "ELB output...(will vary between the 3 websites)"
vBox1Count=0
vBox2Count=0
vBox3Count=0
echo "Start Time: $(date)"
for i in {1..600} ; do
	vELBText=$(curl ${vLoadBalancerDNSName} 2> /dev/null)
	echo "${vLoadBalancerDNSName} --> ${vELBText}"
	if [[ "${vELBText}" != "${vBoxText1}" && "${vELBText}" != "${vBoxText2}" && "${vELBText}" != "${vBoxText3}" ]] ; then
		echo "Unexpected text found. Doesn't match either of the boxes"
	fi
  sleep 3
  
  # check if both sites have been served
  if [[ "${vELBText}" == "${vBoxText1}"  ]] ; then
    vBox1Count=$((vBox1Count + 1))
  fi
  if [[ "${vELBText}" == "${vBoxText2}"  ]] ; then
    vBox2Count=$((vBox2Count + 1))
  fi
  if [[ "${vELBText}" == "${vBoxText3}"  ]] ; then
    vBox3Count=$((vBox3Count + 1))
  fi
  
  if [[ ${vBox1Count} -gt 0 && ${vBox2Count} -gt 0 && ${vBox3Count} -gt 0 ]] ; then
    echo "All websites are serving now!!!. Done!"
    break
  fi
done
echo "End Time: $(date)"

# checking EC2 role(S3 Access) applied, only to Box2
if checkS3Access ${vBox1} ${vKeyFile} ; then 
   echo "Error: Box1 can unexpectedly access S3" >&2
fi

if ! checkS3Access ${vBox2} ${vKeyFile} ; then 
   echo "Error: Box2 can NOT access S3" >&2
fi

# check the instance created using launch template are up
vLaunchTemplateInstancePDNS=$(aws ec2 describe-instances --filter "Name=tag:created_using,Values=ec2_launch_template" "Name=instance-state-name,Values=running" --query Reservations[*].Instances[*].PublicDnsName --output text)
for vInstance in ${vLaunchTemplateInstancePDNS} ; do
  echo "Checking Launch Template Instance: ${vInstance}"
  # check website works
  vBoxText=$(curl ${vInstance} 2> /dev/null || true)
  if [[ "${vBoxText}" != "This Website instance is created using Launch Template"  ]] ; then  
    echo "Incorrect Launch Instance Text found on instance: ${vInstance}, Text: ${vBoxText}" >&2
  fi
  # check EC2 role - instance should be able to access S3  
  if ! checkS3Access ${vInstance} ${vKeyFile} ; then 
    echo "Error: ${vInstance} can NOT access S3" >&2
  fi
done