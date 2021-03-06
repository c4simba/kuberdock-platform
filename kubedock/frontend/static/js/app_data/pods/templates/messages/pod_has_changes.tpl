<div class="message">
    <h3>
      <span class="message-pod-canged-info-title-ico"></span>
      <span>You have some changes in the pod that haven't been applied yet!</span>
    </h3>
    <p>
        <div class="buttons text-center">
        <% if (changesRequirePayment && fixedPrice){ %>
            You'll need to pay additional <%- changesRequirePayment %>/<%- period %>
            after you re-deploy this pod with new containers and configuration.
                <button class="blue pay-and-apply" title="Pod will be restarted">Pay & apply changes</button>
        <% } else { %>
            You need to re-deploy this pod with new containers and configuration.
                <button class="blue apply">Restart & apply changes</button>
        <% } %>
            <button class="gray reset-changes">Reset changes</button>
        </div>
        <% if (typeof template_plan_name != 'undefined' && template_plan_name &&
               (typeof forbidSwitchingAppPackage == 'undefined' || !forbidSwitchingAppPackage)){ %>
            <p>
                <span class="warning">
                    Warnging: if you apply this edit, you won't be able to
                    <a href='#pods/<%- id %>/switch-package'>switch packages</a>
                    for this pod.
                </span>
            </p>
        <% } %>
    </p>
</div>
