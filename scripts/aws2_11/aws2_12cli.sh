#!/bin/bash

# Detener el script si algún comando falla
set -e

OWNER="drg"
ACT="12-cli"
AMI_ID="ami-0d97d7f07b25dd693"
KEY_NAME="vockey"

# 1. Crear la VPC y devolver su ID
VPC_ID=$(aws ec2 create-vpc \
    --cidr-block 172.16.0.0/16 \
    --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=vpc-script-$OWNER-$ACT}]" \
    --query 'Vpc.VpcId' \
    --output text)

echo "VPC creada con ID: $VPC_ID"

# 2. Habilitar DNS en la VPC
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support '{"Value":true}'
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames '{"Value":true}'

# 3. Crear la subred pública y la subred privada (misma AZ)
AZ=$(aws ec2 describe-availability-zones \
    --query 'AvailabilityZones[0].ZoneName' \
    --output text)

SUB_PUB_ID=$(aws ec2 create-subnet \
    --vpc-id "$VPC_ID" \
    --cidr-block 172.16.0.0/20 \
    --availability-zone "$AZ" \
    --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=sbn-publica-$OWNER-$ACT}]" \
    --query 'Subnet.SubnetId' \
    --output text)

echo "Subred pública creada con ID: $SUB_PUB_ID"

SUB_PRIV_ID=$(aws ec2 create-subnet \
    --vpc-id "$VPC_ID" \
    --cidr-block 172.16.64.0/20 \
    --availability-zone "$AZ" \
    --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=sbn-privada-$OWNER-$ACT}]" \
    --query 'Subnet.SubnetId' \
    --output text)

echo "Subred privada creada con ID: $SUB_PRIV_ID"

# 4. Crear el Internet Gateway y asociarlo a la VPC
IGW_ID=$(aws ec2 create-internet-gateway \
    --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=igw-script-$OWNER-$ACT}]" \
    --query 'InternetGateway.InternetGatewayId' \
    --output text)

aws ec2 attach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"

echo "Internet Gateway $IGW_ID creado y asociado a la VPC."

# 5. Tabla de rutas PÚBLICA: 0.0.0.0/0 -> IGW, asociada a la subred pública
RTB_PUB_ID=$(aws ec2 create-route-table \
    --vpc-id "$VPC_ID" \
    --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=rtb-publica-$OWNER-$ACT}]" \
    --query 'RouteTable.RouteTableId' \
    --output text)

aws ec2 create-route \
    --route-table-id "$RTB_PUB_ID" \
    --destination-cidr-block 0.0.0.0/0 \
    --gateway-id "$IGW_ID" > /dev/null

aws ec2 associate-route-table \
    --route-table-id "$RTB_PUB_ID" \
    --subnet-id "$SUB_PUB_ID" > /dev/null

echo "Tabla de rutas pública $RTB_PUB_ID creada y asociada a la subred pública."

# 6. Reservar una IP elástica para la NAT Gateway
EIP_ALLOC_ID=$(aws ec2 allocate-address \
    --domain vpc \
    --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=eip-nat-$OWNER-$ACT}]" \
    --query 'AllocationId' \
    --output text)

echo "IP elástica reservada con AllocationId: $EIP_ALLOC_ID"

# 7. Crear la NAT Gateway en la SUBRED PÚBLICA y esperar a que esté disponible
NAT_ID=$(aws ec2 create-nat-gateway \
    --subnet-id "$SUB_PUB_ID" \
    --allocation-id "$EIP_ALLOC_ID" \
    --connectivity-type public \
    --tag-specifications "ResourceType=natgateway,Tags=[{Key=Name,Value=nat-script-$OWNER-$ACT}]" \
    --query 'NatGateway.NatGatewayId' \
    --output text)

echo "NAT Gateway $NAT_ID creada. Esperando a que esté disponible (1-3 min)..."
aws ec2 wait nat-gateway-available --nat-gateway-ids "$NAT_ID"
echo "NAT Gateway disponible."

# 8. Tabla de rutas PRIVADA: 0.0.0.0/0 -> NAT, asociada a la subred privada
RTB_PRIV_ID=$(aws ec2 create-route-table \
    --vpc-id "$VPC_ID" \
    --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=rtb-privada-$OWNER-$ACT}]" \
    --query 'RouteTable.RouteTableId' \
    --output text)

aws ec2 create-route \
    --route-table-id "$RTB_PRIV_ID" \
    --destination-cidr-block 0.0.0.0/0 \
    --nat-gateway-id "$NAT_ID" > /dev/null

aws ec2 associate-route-table \
    --route-table-id "$RTB_PRIV_ID" \
    --subnet-id "$SUB_PRIV_ID" > /dev/null

echo "Tabla de rutas privada $RTB_PRIV_ID creada y asociada a la subred privada."

# 9. Security Group PÚBLICO: SSH desde cualquier sitio
SG_PUB_ID=$(aws ec2 create-security-group \
    --group-name "sec-ssh-publico-$OWNER-$ACT" \
    --description "SSH desde Internet a la instancia publica" \
    --vpc-id "$VPC_ID" \
    --query 'GroupId' \
    --output text)

aws ec2 authorize-security-group-ingress \
    --group-id "$SG_PUB_ID" \
    --protocol tcp --port 22 --cidr 0.0.0.0/0 \
    --tag-specifications "ResourceType=security-group-rule,Tags=[{Key=Name,Value=sgr-allow-ssh-$OWNER-$ACT}]" > /dev/null

echo "Security Group público creado con ID: $SG_PUB_ID"

# 10. Security Group PRIVADO: SSH solo desde el SG público
SG_PRIV_ID=$(aws ec2 create-security-group \
    --group-name "sec-ssh-privado-$OWNER-$ACT" \
    --description "SSH desde la instancia publica" \
    --vpc-id "$VPC_ID" \
    --query 'GroupId' \
    --output text)

aws ec2 authorize-security-group-ingress \
    --group-id "$SG_PRIV_ID" \
    --protocol tcp --port 22 --source-group "$SG_PUB_ID" \
    --tag-specifications "ResourceType=security-group-rule,Tags=[{Key=Name,Value=sgr-allow-ssh-bastion-$OWNER-$ACT}]" > /dev/null

echo "Security Group privado creado con ID: $SG_PRIV_ID"

# 11. Instancia EC2 PÚBLICA (bastión) con IP pública e IP privada fija
INSTANCE_PUB_ID=$(aws ec2 run-instances \
    --image-id "$AMI_ID" \
    --instance-type t2.micro \
    --key-name "$KEY_NAME" \
    --subnet-id "$SUB_PUB_ID" \
    --private-ip-address 172.16.0.100 \
    --security-group-ids "$SG_PUB_ID" \
    --associate-public-ip-address \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=ec2-publica-$OWNER-$ACT}]" \
    --query 'Instances[0].InstanceId' \
    --output text)

echo "Instancia pública creada con ID: $INSTANCE_PUB_ID"

# 12. Instancia EC2 PRIVADA sin IP pública (sale a Internet por la NAT)
INSTANCE_PRIV_ID=$(aws ec2 run-instances \
    --image-id "$AMI_ID" \
    --instance-type t2.micro \
    --key-name "$KEY_NAME" \
    --subnet-id "$SUB_PRIV_ID" \
    --private-ip-address 172.16.64.100 \
    --security-group-ids "$SG_PRIV_ID" \
    --no-associate-public-ip-address \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=ec2-privada-$OWNER-$ACT}]" \
    --query 'Instances[0].InstanceId' \
    --output text)

echo "Instancia privada creada con ID: $INSTANCE_PRIV_ID"

# 13. Esperar a que ambas instancias arranquen y mostrar el resumen
echo "Esperando a que las instancias estén en ejecución..."
aws ec2 wait instance-running --instance-ids "$INSTANCE_PUB_ID" "$INSTANCE_PRIV_ID"

IP_PUBLICA=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_PUB_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text)

IP_NAT=$(aws ec2 describe-nat-gateways \
    --nat-gateway-ids "$NAT_ID" \
    --query 'NatGateways[0].NatGatewayAddresses[0].PublicIp' \
    --output text)

echo ""
echo "================= PROCESO COMPLETADO ================="
echo "VPC: $VPC_ID | IGW: $IGW_ID"
echo "Subred pública: $SUB_PUB_ID | Subred privada: $SUB_PRIV_ID"
echo "RT pública: $RTB_PUB_ID | RT privada: $RTB_PRIV_ID"
echo "NAT Gateway: $NAT_ID | IP elástica NAT: $IP_NAT"
echo "SG público: $SG_PUB_ID | SG privado: $SG_PRIV_ID"
echo "EC2 pública: $INSTANCE_PUB_ID (172.16.0.100 / $IP_PUBLICA)"
echo "EC2 privada: $INSTANCE_PRIV_ID (172.16.64.100)"
echo "===================================================="