#!/bin/bash

# Detener el script si algún comando falla
set -e

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

# 4. Crear el Internet Gateway y asociarlo a la VPC
IGW_ID=$(aws ec2 create-internet-gateway \
    --tag-specifications 'ResourceType=internet-gateway,Tags=[{Key=Name,Value=igw-script-davidreinon}]' \
    --query 'InternetGateway.InternetGatewayId' \
    --output text)

aws ec2 attach-internet-gateway \
    --internet-gateway-id "$IGW_ID" \
    --vpc-id "$VPC_ID"

echo "Internet Gateway $IGW_ID creado y asociado a la VPC."

# 5. Crear la tabla de rutas, añadir la ruta a Internet y asociarla a la subred
RTB_ID=$(aws ec2 create-route-table \
    --vpc-id "$VPC_ID" \
    --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=rtb-script-davidreinon}]' \
    --query 'RouteTable.RouteTableId' \
    --output text)

aws ec2 create-route \
    --route-table-id "$RTB_ID" \
    --destination-cidr-block 0.0.0.0/0 \
    --gateway-id "$IGW_ID" > /dev/null

aws ec2 associate-route-table \
    --route-table-id "$RTB_ID" \
    --subnet-id "$SUB_ID" > /dev/null

echo "Tabla de rutas $RTB_ID creada y asociada a la subred."

# 6. Crear el Security Group y guardar su ID en una variable (SG_ID)
SG_ID=$(aws ec2 create-security-group \
    --group-name "sec-ssh-davidreinon" \
    --description "Grupo de seguridad para permitir acceso SSH" \
    --vpc-id "$VPC_ID" \
    --query 'GroupId' \
    --output text)

echo "Security Group creado con ID: $SG_ID"

# 7. Añadir regla de entrada (Ingress) para SSH (Puerto 22)
aws ec2 authorize-security-group-ingress \
    --group-id "$SG_ID" \
    --protocol tcp \
    --port 22 \
    --cidr 0.0.0.0/0 \
    --tag-specifications 'ResourceType=security-group-rule,Tags=[{Key=Name,Value=sgr-allow-ssh}]' > /dev/null

echo "Regla SSH (puerto 22) añadida al Security Group."

# 8. Crear la instancia EC2 utilizando la subred y el Security Group creados
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

# 9. Esperar a que la instancia arranque y mostrar su IP pública
echo "Esperando a que la instancia esté en ejecución..."
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"

IP_PUBLICA=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text)

echo "Proceso completado."
echo "VPC: $VPC_ID | Subred: $SUB_ID | IGW: $IGW_ID | Tabla de rutas: $RTB_ID"
echo "SG: $SG_ID | Instancia: $INSTANCE_ID | IP pública: $IP_PUBLICA"
echo "Conéctate con: ssh -i vockey.pem <usuario>@$IP_PUBLICA"