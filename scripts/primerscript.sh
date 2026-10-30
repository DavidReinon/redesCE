#!/bin/bash

# 1. Crear la VPC y devolver su ID
VPC_ID=$(aws ec2 create-vpc \
    --cidr-block 172.16.0.0/16 \
    --tag-specifications 'ResourceType=vpc,Tags=[{Key=Name,Value=vpc-script-davidreinon}]' \
    --query 'Vpc.VpcId' \
    --output text)

echo "VPC creada con ID: $VPC_ID"

# 2. Habilitar DNS en la VPC
aws ec2 modify-vpc-attribute \
    --vpc-id "$VPC_ID" \
    --enable-dns-support '{"Value":true}'

aws ec2 modify-vpc-attribute \
    --vpc-id "$VPC_ID" \
    --enable-dns-hostnames '{"Value":true}'

# 3. Crear la subred y guardar su ID
SUB_ID=$(aws ec2 create-subnet \
    --vpc-id "$VPC_ID" \
    --cidr-block 172.16.0.0/20 \
    --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=sbn-script-davidreinon}]' \
    --query 'Subnet.SubnetId' \
    --output text)

echo "Subred creada con ID: $SUB_ID"

# 4. Crear el Security Group y guardar su ID en una variable (SG_ID)
SG_ID=$(aws ec2 create-security-group \
    --group-name "sec-ssh-davidreinon" \
    --description "Grupo de seguridad para permitir acceso SSH" \
    --vpc-id "$VPC_ID" \
    --query 'GroupId' \
    --output text)

echo "Security Group creado con ID: $SG_ID"

# 5. Añadir regla de entrada (Ingress) para SSH (Puerto 22)
aws ec2 authorize-security-group-ingress \
    --group-id "$SG_ID" \
    --protocol tcp \
    --port 22 \
    --cidr 0.0.0.0/0 \
    --tag-specifications 'ResourceType=security-group-rule,Tags=[{Key=Name,Value=sgr-allow-ssh}]'

echo "Regla SSH (puerto 22) añadida al Security Group."

# 6. Crear la instancia EC2 utilizando la subred y el Security Group creados
AMI_ID="ami-0d97d7f07b25dd693" 

INSTANCE_ID=$(aws ec2 run-instances \
    --image-id "$AMI_ID" \
    --instance-type t2.micro \
    --key-name vockey \
    --subnet-id "$SUB_ID" \
    --security-group-ids "$SG_ID" \
    --associate-public-ip-address \
    --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=ec2-script-davidreinon}]' \
    --query 'Instances[0].InstanceId' \
    --output text)

echo "Instancia EC2 creada con ID: $INSTANCE_ID"