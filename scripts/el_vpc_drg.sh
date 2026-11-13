#!/bin/bash
# Elimina las VPC con la etiqueta tipo=prueba y todos sus recursos dependientes

VPC_IDS=$(aws ec2 describe-vpcs \
    --filters "Name=tag:tipo,Values=prueba" \
    --query "Vpcs[*].VpcId" \
    --output text)

if [ -z "$VPC_IDS" ]; then
    echo "No hay ninguna VPC con la etiqueta tipo=prueba."
    exit 0
fi

echo "Se van a eliminar estas VPC y todos sus recursos: $VPC_IDS"
read -r -p "¿Continuar? (s/n) " RESP
[ "$RESP" != "s" ] && echo "Cancelado." && exit 0

for VPC_ID in $VPC_IDS; do
    echo "=== Eliminando VPC $VPC_ID ==="

    # 1. Terminar las instancias EC2 y liberar sus IP elásticas
    INSTANCE_IDS=$(aws ec2 describe-instances \
        --filters "Name=vpc-id,Values=$VPC_ID" \
                  "Name=instance-state-name,Values=pending,running,stopping,stopped" \
        --query "Reservations[*].Instances[*].InstanceId" \
        --output text)

    if [ -n "$INSTANCE_IDS" ]; then
        # Guardar las IP elásticas antes de terminar las instancias
        ALLOC_IDS=$(aws ec2 describe-addresses \
            --filters "Name=instance-id,Values=$(echo $INSTANCE_IDS | tr ' ' ',')" \
            --query "Addresses[*].AllocationId" \
            --output text)

        aws ec2 terminate-instances --instance-ids $INSTANCE_IDS > /dev/null
        echo " Terminando instancias: $(echo $INSTANCE_IDS) (esperando...)"
        aws ec2 wait instance-terminated --instance-ids $INSTANCE_IDS
        echo " Instancias terminadas."

        for ALLOC_ID in $ALLOC_IDS; do
            aws ec2 release-address --allocation-id "$ALLOC_ID" && \
                echo " IP elástica $ALLOC_ID liberada."
        done
    fi

    # 2. Separar y eliminar los Internet Gateways
    IGW_IDS=$(aws ec2 describe-internet-gateways \
        --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
        --query "InternetGateways[*].InternetGatewayId" \
        --output text)
    for IGW_ID in $IGW_IDS; do
        aws ec2 detach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"
        aws ec2 delete-internet-gateway --internet-gateway-id "$IGW_ID" && \
            echo " Internet Gateway $IGW_ID eliminado."
    done

    # 3. Eliminar las subredes
    SUBNET_IDS=$(aws ec2 describe-subnets \
        --filters "Name=vpc-id,Values=$VPC_ID" \
        --query "Subnets[*].SubnetId" \
        --output text)
    for SUBNET_ID in $SUBNET_IDS; do
        aws ec2 delete-subnet --subnet-id "$SUBNET_ID" && \
            echo " Subred $SUBNET_ID eliminada."
    done

    # 4. Eliminar las tablas de rutas (la principal se borra con la VPC)
    MAIN_RTB=$(aws ec2 describe-route-tables \
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=association.main,Values=true" \
        --query "RouteTables[0].RouteTableId" \
        --output text)
    RTB_IDS=$(aws ec2 describe-route-tables \
        --filters "Name=vpc-id,Values=$VPC_ID" \
        --query "RouteTables[*].RouteTableId" \
        --output text)
    for RTB_ID in $RTB_IDS; do
        [ "$RTB_ID" = "$MAIN_RTB" ] && continue
        # Quitar primero las asociaciones con subredes que pueda tener
        ASSOC_IDS=$(aws ec2 describe-route-tables \
            --route-table-ids "$RTB_ID" \
            --query 'RouteTables[0].Associations[?!Main].RouteTableAssociationId' \
            --output text)
        for ASSOC_ID in $ASSOC_IDS; do
            aws ec2 disassociate-route-table --association-id "$ASSOC_ID"
        done
        aws ec2 delete-route-table --route-table-id "$RTB_ID" && \
            echo " Tabla de rutas $RTB_ID eliminada."
    done

    # 5. Eliminar los grupos de seguridad (el "default" se borra con la VPC)
    SG_IDS=$(aws ec2 describe-security-groups \
        --filters "Name=vpc-id,Values=$VPC_ID" \
        --query "SecurityGroups[?GroupName!='default'].GroupId" \
        --output text)
    for SG_ID in $SG_IDS; do
        aws ec2 delete-security-group --group-id "$SG_ID" && \
            echo " Security Group $SG_ID eliminado."
    done

    # 6. Eliminar la VPC
    if aws ec2 delete-vpc --vpc-id "$VPC_ID"; then
        echo "VPC $VPC_ID eliminada."
    else
        echo "ERROR: no se pudo eliminar la VPC $VPC_ID (revisa los errores anteriores)."
    fi
done