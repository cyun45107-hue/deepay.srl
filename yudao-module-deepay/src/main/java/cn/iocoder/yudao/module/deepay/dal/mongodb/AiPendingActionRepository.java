package cn.iocoder.yudao.module.deepay.dal.mongodb;

import org.springframework.data.mongodb.repository.MongoRepository;
import org.springframework.stereotype.Repository;

import java.util.List;

/**
 * 待确认工具动作 Repository。
 */
@Repository
public interface AiPendingActionRepository extends MongoRepository<AiPendingActionDocument, String> {

    List<AiPendingActionDocument> findByTenantIdAndSessionIdAndStatus(
            Long tenantId, String sessionId, String status);

}
