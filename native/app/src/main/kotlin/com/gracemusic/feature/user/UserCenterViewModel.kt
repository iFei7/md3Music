package com.gracemusic.feature.user

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.gracemusic.data.account.AccountRepository
import com.gracemusic.data.account.AuthState
import dagger.hilt.android.lifecycle.HiltViewModel
import javax.inject.Inject
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch

/**
 * 「我的」页 ViewModel（T-P4-11 入口侧）。
 *
 * 只做两件事：把 `AccountRepository.authState` 透传给 UI（登录态的唯一真相在
 * `AccountRepository`，本类**不**复制一份状态），以及转发登出。
 */
@HiltViewModel
class UserCenterViewModel @Inject constructor(
    private val accountRepository: AccountRepository,
) : ViewModel() {

    /** 登录态（权威来自 [AccountRepository]）。 */
    val authState: StateFlow<AuthState> = accountRepository.authState

    /** 退出登录。 */
    fun logout() {
        viewModelScope.launch { accountRepository.logout() }
    }

    /** 冷启动恢复登录态（页面首次可见时由 UI 调用一次）。 */
    fun restoreSession() {
        viewModelScope.launch { accountRepository.restoreSession() }
    }
}
